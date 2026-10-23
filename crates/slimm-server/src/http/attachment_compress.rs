// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The space's photo compression, applied to an upload between the checks that
//! admit it and the moment it is stored. Shared by the single-request upload
//! and the resumable one, which differ only in where the received bytes wait.

use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};
use uuid::Uuid;

use super::AppState;
use super::error::ApiError;
use super::storage_room::reserve_room;
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
    let (slot, bytes) = match header_candidate(path, kind).await {
        Some(candidate) => {
            let estimate = compress::peak_bytes(candidate, size, &compress::DEFAULT_SETTINGS);
            let Some(slot) = state.media.admit_memory(estimate).await else {
                refused(estimate);
                return Ok(None);
            };
            (slot, read_upload(path).await)
        }
        None => {
            // The size is not known until the file is read, so the source bytes are reserved first.
            let Some(slot) = state.media.admit_memory(size).await else {
                return Ok(None);
            };
            (slot, read_upload(path).await)
        }
    };
    let Some(bytes) = bytes else {
        return Ok(None);
    };
    let Some(candidate) = compress::inspect(kind, &bytes) else {
        return Ok(None);
    };
    let mut slot = slot;
    let estimate = compress::peak_bytes(candidate, size, &compress::DEFAULT_SETTINGS);
    let held = slot.num_permits() as u64 * MIB;
    if held < estimate {
        match state.media.admit_memory(estimate - held).await {
            Some(rest) => slot.merge(rest),
            None => {
                refused(estimate);
                return Ok(None);
            }
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

const MIB: u64 = 1024 * 1024;

/// How much of the file is read to learn its dimensions before it is read whole.
const HEADER_BYTES: usize = 1024 * 1024;

fn refused(estimate: u64) {
    tracing::warn!(
        estimate,
        "no room to compress an upload; storing it as sent"
    );
}

async fn read_upload(path: &Path) -> Option<Vec<u8>> {
    match tokio::fs::read(path).await {
        Ok(bytes) => Some(bytes),
        Err(err) => {
            tracing::warn!(error = %err, "could not read an upload to compress it");
            None
        }
    }
}

/// The file's format and size from its first bytes alone, so its memory can be reserved before it is read.
async fn header_candidate(path: &Path, kind: compress::Kind) -> Option<compress::Candidate> {
    use tokio::io::AsyncReadExt;
    let mut head = Vec::with_capacity(HEADER_BYTES);
    let file = tokio::fs::File::open(path).await.ok()?;
    file.take(HEADER_BYTES as u64)
        .read_to_end(&mut head)
        .await
        .ok()?;
    compress::inspect(kind, &head)
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
        let _reservation = match reserve_room(state, size.saturating_add(kept), None).await {
            Ok(reservation) => reservation,
            Err(err) => {
                received.discard().await.ok();
                return Err(err);
            }
        };
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
        state
            .media
            .prewarm_preview(&hex_id, compressed.content_type);
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
