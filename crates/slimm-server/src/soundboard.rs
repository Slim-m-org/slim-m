// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Soundboard clips: validation and creation (decision 0118).
//!
//! Clips are mp3 or wav, the two types every shipped client decodes. The type
//! is sniffed from the bytes and the length is read from them too, so a clip
//! cannot claim to be shorter than it is.

pub mod duration;
pub mod starter;

use sha2::{Digest, Sha256};

use crate::ids::{SoundClipId, UserId};
use crate::media::{self, Media};
use crate::store::{ClipEmoji, SoundClip, SoundClipError, Store};

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
    /// No custom emoji answers to the clip's emoji.
    UnknownEmoji,
    Storage(anyhow::Error),
}

/// Trims a clip name and refuses an empty, over-long or hidden-character one.
pub fn normalize_name(raw: &str) -> Option<String> {
    let name = raw.trim();
    let usable = !name.is_empty()
        && name.chars().count() <= MAX_NAME_CHARS
        && !name.chars().any(crate::hidden_chars::is_hidden_char);
    usable.then(|| name.to_owned())
}

/// A clip that passed every check that needs no I/O.
#[derive(Debug)]
pub struct ValidatedClip {
    pub name: String,
    pub content_type: &'static str,
    pub duration_ms: i64,
    pub sha256: Vec<u8>,
    pub bytes: Vec<u8>,
}

/// The name, size, type and length checks every clip passes, uploaded or bundled.
pub fn validate(raw_name: &str, bytes: Vec<u8>) -> Result<ValidatedClip, AddError> {
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
    Ok(ValidatedClip {
        name,
        content_type,
        duration_ms,
        sha256: Sha256::digest(&bytes).to_vec(),
        bytes,
    })
}

/// Stores `bytes` and records a clip named `raw_name`, shown with `emoji`.
///
/// Every check that costs no I/O runs first, then the name, cap and emoji, then
/// the bytes, then the row: the order `emoji::add_emoji` uses, for the same reason.
pub async fn add_clip(
    store: &Store,
    media: &Media,
    raw_name: &str,
    emoji: Option<ClipEmoji<'_>>,
    bytes: Vec<u8>,
    uploader: UserId,
) -> Result<SoundClip, AddError> {
    let clip = validate(raw_name, bytes)?;
    if let Some(refusal) = store
        .sound_clip_refusal(&clip.name, emoji)
        .await
        .map_err(AddError::Storage)?
    {
        return Err(refused(refusal));
    }
    store_bytes(store, media, &clip, Some(uploader))
        .await
        .map_err(AddError::Storage)?;
    store
        .create_sound_clip(
            SoundClipId::generate(),
            &clip.name,
            emoji,
            &clip.sha256,
            clip.duration_ms,
            uploader,
        )
        .await
        .map_err(AddError::Storage)?
        .map_err(refused)
}

/// Writes a clip's bytes and their `attachments` row under the blob guard, so
/// the orphan sweep cannot unlink them between the two.
pub(crate) async fn store_bytes(
    store: &Store,
    media: &Media,
    clip: &ValidatedClip,
    uploader: Option<UserId>,
) -> anyhow::Result<()> {
    let _placing = media.blob_guard().await;
    media
        .write_attachment(&media::to_hex(&clip.sha256), clip.bytes.clone())
        .await?;
    store
        .store_attachment(
            &clip.sha256,
            clip.bytes.len() as i64,
            clip.content_type,
            &format!("{}.clip", clip.name),
            uploader,
        )
        .await
}

/// The one place a store-level refusal becomes an [`AddError`].
pub(crate) fn refused(err: SoundClipError) -> AddError {
    match err {
        SoundClipError::NameTaken => AddError::NameTaken,
        SoundClipError::Full => AddError::Full,
        SoundClipError::UnknownEmoji => AddError::UnknownEmoji,
    }
}

#[cfg(test)]
mod name_tests {
    use super::normalize_name;

    #[test]
    fn a_name_with_an_invisible_or_direction_character_is_refused() {
        assert_eq!(normalize_name(" honk "), Some("honk".to_owned()));
        assert_eq!(normalize_name("ho\u{200B}nk"), None);
        assert_eq!(normalize_name("\u{202E}knoh"), None);
    }
}
