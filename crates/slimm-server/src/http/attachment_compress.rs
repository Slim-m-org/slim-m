// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The space's photo compression, applied to an upload between the checks that
//! admit it and the moment it is stored. Shared by the single-request upload
//! and the resumable one, which differ only in where the received bytes wait.

use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};
use uuid::Uuid;

use super::AppState;
use super::attachments::room_for;
use super::error::ApiError;
use crate::ids::UserId;
use crate::media::compress::{self, Compressed, Policy};
use crate::media::{self, PendingAttachment, Uploads};
use crate::store::{AttachmentSummary, KeptOriginal, OriginalInfo};

/// Where the bytes as uploaded wait, until they are kept as the original or dropped.
pub(super) enum Received {
    Pending(PendingAttachment),
    Session(Uploads, Uuid),
}

impl Received {
    async fn keep_at(self, dest: PathBuf) -> std::io::Result<()> {
        match self {
            Self::Pending(pending) => pending.commit_at(dest).await,
            Self::Session(uploads, id) => uploads.place_at(id, dest).await,
        }
    }

    async fn discard(self) -> std::io::Result<()> {
        match self {
            Self::Pending(pending) => pending.abandon().await,
            Self::Session(uploads, id) => uploads.discard(id).await,
        }
    }
}

/// A compressed stand-in for an upload, ready to be stored.
pub(super) struct Replacement {
    compressed: Compressed,
    hex_id: String,
    filename: String,
    original: Option<KeptOriginal>,
}

/// The compressed version of the file at `path`, or `None` when compression is
/// off, the file is not an eligible photo, or it would not get meaningfully
/// smaller. `prefix` is the file's leading bytes, from the upload's own sniff.
pub(super) async fn prepare(
    state: &AppState,
    path: &Path,
    size: u64,
    prefix: &[u8],
    filename: &str,
) -> Result<Option<Replacement>, ApiError> {
    let settings = state.store.media_compression().await?;
    if !settings.enabled || size > compress::MAX_SOURCE_BYTES {
        return Ok(None);
    }
    let policy = Policy {
        extensions: settings.extensions,
        metadata: settings.metadata,
    };
    let Some(kind) = compress::eligible_kind(prefix, &policy) else {
        return Ok(None);
    };
    // The source bytes are reserved before they are read, the rest of the peak once it is known.
    let Some(mut slot) = state.media.admit_compression(size).await else {
        return Ok(None);
    };
    let bytes = match tokio::fs::read(path).await {
        Ok(bytes) => bytes,
        Err(err) => {
            tracing::warn!(error = %err, "could not read an upload to compress it");
            return Ok(None);
        }
    };
    let Some(candidate) = compress::inspect(kind, &bytes) else {
        return Ok(None);
    };
    let estimate = compress::peak_bytes(candidate, size, &compress::DEFAULT_SETTINGS);
    match state
        .media
        .admit_compression(estimate.saturating_sub(size))
        .await
    {
        Some(rest) => slot.merge(rest),
        None => {
            tracing::warn!(
                estimate,
                "no room to compress an upload; storing it as sent"
            );
            return Ok(None);
        }
    }
    let _slot = slot;
    let compressed = tokio::task::spawn_blocking(move || {
        compress::compress(candidate, &bytes, &policy, &compress::DEFAULT_SETTINGS)
    })
    .await
    .unwrap_or_else(|err| {
        tracing::error!(error = %err, "photo compression panicked; storing the upload as sent");
        None
    });
    Ok(compressed.map(|compressed| {
        let hex_id = media::to_hex(&Sha256::digest(&compressed.bytes));
        let original = settings.keep_original.then(|| KeptOriginal {
            size: i64::try_from(size).unwrap_or(i64::MAX),
            content_type: media::attachment_content_type(prefix).to_owned(),
            filename: filename.to_owned(),
        });
        Replacement {
            filename: renamed(filename, &compressed, prefix),
            compressed,
            hex_id,
            original,
        }
    }))
}

/// The upload's name, with the extension of the format it was converted to when that changed.
fn renamed(filename: &str, compressed: &Compressed, prefix: &[u8]) -> String {
    if media::sniff_content_type(prefix) == Some(compressed.content_type) {
        return filename.to_owned();
    }
    let stem = filename.rsplit_once('.').map_or(filename, |(stem, _)| stem);
    let stem = if stem.is_empty() { "file" } else { stem };
    format!("{stem}.{}", compressed.extension)
}

impl Replacement {
    /// Stores the compressed file and its row, keeping or dropping the original,
    /// and describes the attachment a client now references.
    pub(super) async fn store(
        self,
        state: &AppState,
        uploader: UserId,
        received: Received,
    ) -> Result<AttachmentSummary, ApiError> {
        let Self {
            compressed,
            hex_id,
            filename,
            original,
        } = self;
        let size = i64::try_from(compressed.bytes.len()).unwrap_or(i64::MAX);
        let kept = original.as_ref().map_or(0, |o| o.size);
        if let Err(err) = room_for(state, size.saturating_add(kept)).await {
            received.discard().await.ok();
            return Err(err);
        }
        let sha256 = media::from_hex(&hex_id).expect("a hex id from sha256 is well-formed hex");
        let placing = state.media.blob_guard().await;
        let stored = async {
            state
                .media
                .write_attachment(&hex_id, compressed.bytes)
                .await?;
            match &original {
                Some(_) => received.keep_at(state.media.original_path(&hex_id)).await,
                None => received.discard().await,
            }
        }
        .await;
        stored.map_err(|err| {
            tracing::error!(error = %err, "failed to store a compressed attachment");
            ApiError::Internal
        })?;
        match &original {
            Some(original) => {
                state
                    .store
                    .store_attachment_with_original(
                        &sha256,
                        size,
                        compressed.content_type,
                        &filename,
                        Some(uploader),
                        original,
                    )
                    .await?;
            }
            None => {
                state
                    .store
                    .store_attachment(
                        &sha256,
                        size,
                        compressed.content_type,
                        &filename,
                        Some(uploader),
                    )
                    .await?;
            }
        }
        drop(placing);
        Ok(AttachmentSummary {
            id: hex_id,
            filename,
            content_type: compressed.content_type.to_owned(),
            size,
            spoiler: false,
            original: original.map(|o| OriginalInfo {
                size: o.size,
                filename: o.filename,
            }),
        })
    }
}
