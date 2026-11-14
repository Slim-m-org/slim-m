// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Soundboard clips: validation and creation (decision 0118).
//!
//! Clips are mp3 or wav, the two types every shipped client decodes. The type
//! is sniffed from the bytes and the length is read from them too, so a clip
//! cannot claim to be shorter than it is.

pub mod duration;

use sha2::{Digest, Sha256};

use crate::ids::{SoundClipId, UserId};
use crate::media::{self, Media};
use crate::store::{SoundClip, SoundClipError, Store};

/// Largest clip upload, in bytes.
pub const MAX_CLIP_BYTES: u64 = 512 * 1024;

/// Longest clip, in milliseconds.
pub const MAX_CLIP_MS: i64 = 5_000;

/// Longest clip name, in characters.
pub const MAX_NAME_CHARS: usize = 32;

/// Why a clip write was refused.
#[derive(Debug)]
pub enum AddError {
    UnusableName,
    Empty,
    TooLarge,
    UnsupportedType,
    /// The bytes sniff as audio but no length could be read from them.
    UnreadableLength,
    TooLong,
    NameTaken,
    Full,
    Storage(anyhow::Error),
}

/// Trims a clip name and refuses an empty, over-long or control-laden one.
pub fn normalize_name(raw: &str) -> Option<String> {
    let name = raw.trim();
    let usable = !name.is_empty()
        && name.chars().count() <= MAX_NAME_CHARS
        && !name.chars().any(char::is_control);
    usable.then(|| name.to_owned())
}

/// Stores `bytes` and records a clip named `raw_name`.
///
/// Every check that costs no I/O runs first, then the name and cap, then the
/// bytes, then the row: the order `emoji::add_emoji` uses, for the same reason.
pub async fn add_clip(
    store: &Store,
    media: &Media,
    raw_name: &str,
    bytes: Vec<u8>,
    uploader: UserId,
) -> Result<SoundClip, AddError> {
    let name = normalize_name(raw_name).ok_or(AddError::UnusableName)?;
    if bytes.is_empty() {
        return Err(AddError::Empty);
    }
    if bytes.len() as u64 > MAX_CLIP_BYTES {
        return Err(AddError::TooLarge);
    }
    let content_type = match media::sniff_content_type(&bytes) {
        Some(kind @ ("audio/mpeg" | "audio/wav")) => kind,
        _ => return Err(AddError::UnsupportedType),
    };
    let duration_ms = duration::of(&bytes, content_type).ok_or(AddError::UnreadableLength)?;
    if duration_ms > MAX_CLIP_MS {
        return Err(AddError::TooLong);
    }

    if let Some(refusal) = store
        .sound_clip_refusal(&name)
        .await
        .map_err(AddError::Storage)?
    {
        return Err(refused(refusal));
    }

    let sha256 = Sha256::digest(&bytes).to_vec();
    let size = bytes.len() as i64;
    let placing = media.blob_guard().await;
    media
        .write_attachment(&media::to_hex(&sha256), bytes)
        .await
        .map_err(|err| AddError::Storage(err.into()))?;
    store
        .store_attachment(
            &sha256,
            size,
            content_type,
            &format!("{name}.clip"),
            Some(uploader),
        )
        .await
        .map_err(AddError::Storage)?;
    drop(placing);

    store
        .create_sound_clip(
            SoundClipId::generate(),
            &name,
            &sha256,
            duration_ms,
            uploader,
        )
        .await
        .map_err(AddError::Storage)?
        .map_err(refused)
}

/// The one place a store-level refusal becomes an [`AddError`].
pub(crate) fn refused(err: SoundClipError) -> AddError {
    match err {
        SoundClipError::NameTaken => AddError::NameTaken,
        SoundClipError::Full => AddError::Full,
    }
}
