// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Custom emoji naming and creation, shared by every path that adds one.
//!
//! There is exactly one normaliser and exactly one create path in this crate.
//! The HTTP upload (`http::emoji`) and the bulk import ([`import`]) both call
//! [`add_emoji`], which normalises the name itself, so neither caller can
//! forget to. Two normalisers that drift is how `:party_parrot:` stops
//! matching itself, and one shared create path is why the two cannot disagree
//! about where the bytes live either.
//!
//! slim-m ships no emoji of its own. Nothing here bundles, fetches or seeds a
//! set; it only takes what an operator supplies.

pub mod builtin;
pub mod bulk;
pub mod import;

use sha2::{Digest, Sha256};

use crate::ids::{EmojiId, UserId};
use crate::media::{self, Media};
use crate::store::{CreateEmojiError, CustomEmoji, Store};

/// Longest `:shortcode:` accepted. Long enough for a readable name, short
/// enough that the list stays a list rather than a wall.
pub const MAX_NAME_LEN: usize = 32;

/// Emoji are drawn inline at text size, so the ceiling is far below an
/// attachment's: a megabyte is already generous for something rendered at
/// about 20 points.
///
/// Named for the image rather than "emoji bytes" because
/// [`crate::store::MAX_EMOJI_BYTES`] is a different limit entirely (the length
/// of a unicode reaction string), and two constants of one name would be read
/// as one.
pub const MAX_IMAGE_BYTES: u64 = 1024 * 1024;

/// Why a raw name yields no `:shortcode:`. Two cases rather than one because
/// they send whoever reads the message to different places: the first says
/// look at the characters, the second says the characters are fine.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NameProblem {
    /// Nothing typeable between colons survived.
    Unusable,
    /// Every surviving character is legal, there are just more than
    /// [`MAX_NAME_LEN`] of them.
    TooLong { length: usize },
}

/// Why adding an emoji was refused. Every caller maps these to its own
/// vocabulary: HTTP status codes for an upload, a report line for an import.
#[derive(Debug)]
pub enum AddError {
    /// [`normalize_name`] found no usable `:shortcode:`. One variant rather
    /// than a [`NameProblem`] because this error's readers answer a request
    /// with a message that already names both bounds; the bulk import reads
    /// the problem itself, since a report has room to say which.
    UnusableName,
    /// No bytes at all.
    Empty,
    /// Over [`MAX_IMAGE_BYTES`].
    TooLarge,
    /// The bytes are not an image this server stores and serves inline.
    UnsupportedType,
    /// Wider or taller than [`media::MAX_EMOJI_SIDE`], or over the pixel cap.
    TooManyPixels,
    /// Another emoji already answers to this name.
    NameTaken,
    /// The name is a standard unicode emoji's shortcode, which a custom emoji
    /// would shadow.
    BuiltinName,
    /// The deployment is at [`crate::store::MAX_CUSTOM_EMOJI`].
    Full,
    /// The database or the blob directory refused the write. Not a property
    /// of the input: the same call would fail for any emoji.
    Storage(anyhow::Error),
}

/// Lowercases and accepts only what a member can type unambiguously between
/// colons.
///
/// The two failures are separate because folding them loses the one thing
/// whoever reads the refusal needs: a downloaded pack names its files at
/// length, so "too long" is the common case, and telling someone their legal
/// characters are illegal sends them hunting for a character that is not
/// there.
pub fn normalize_name(raw: &str) -> Result<String, NameProblem> {
    let name: String = raw
        .trim()
        .to_ascii_lowercase()
        .chars()
        .map(|c| if c == ' ' || c == '-' { '_' } else { c })
        .filter(|c| c.is_ascii_alphanumeric() || *c == '_')
        .collect();
    if name.is_empty() {
        return Err(NameProblem::Unusable);
    }
    if name.len() > MAX_NAME_LEN {
        return Err(NameProblem::TooLong { length: name.len() });
    }
    Ok(name)
}

/// One image that has passed every check [`add_emoji`] and [`bulk`] apply
/// before a single byte reaches the store: a usable name, non-empty, under
/// [`MAX_IMAGE_BYTES`], and sniffed as an inline image type.
///
/// Split out of [`add_emoji`] so the bulk path can validate a whole batch
/// before writing any of it without re-deriving these rules a second time -
/// two normalisers or two size checks that drift is exactly how `:shortcode:`
/// stopped matching itself for the single upload and the CLI importer, and
/// this is the same fix applied one level up.
pub struct ValidatedImage {
    pub name: String,
    pub content_type: &'static str,
    pub bytes: Vec<u8>,
    pub sha256: Vec<u8>,
}

/// Runs every check on `bytes` and `raw_name` that costs no I/O: normalising
/// the name, the empty and [`MAX_IMAGE_BYTES`] checks, and sniffing the
/// content type against the inline allowlist. What this does not check is
/// whether the name collides with an existing emoji or the deployment is at
/// its cap - those need the store, and [`add_emoji`] and [`bulk::add_emoji_bulk`]
/// each ask it at the point that makes sense for their own shape.
pub fn validate_image(raw_name: &str, bytes: Vec<u8>) -> Result<ValidatedImage, AddError> {
    let name = normalize_name(raw_name).map_err(|_| AddError::UnusableName)?;
    if builtin::is_builtin_name(&name) {
        return Err(AddError::BuiltinName);
    }
    if bytes.is_empty() {
        return Err(AddError::Empty);
    }
    if bytes.len() as u64 > MAX_IMAGE_BYTES {
        return Err(AddError::TooLarge);
    }
    // Inline pictures only, since an emoji is drawn rather than downloaded; it may animate.
    let content_type = media::check_image(
        &bytes,
        media::Motion::AnimatedAllowed,
        media::MAX_EMOJI_SIDE,
    )
    .map_err(|problem| match problem {
        media::ImageProblem::TooLarge => AddError::TooManyPixels,
        media::ImageProblem::Unsupported | media::ImageProblem::Animated => {
            AddError::UnsupportedType
        }
    })?
    .content_type;
    let sha256 = Sha256::digest(&bytes).to_vec();
    Ok(ValidatedImage {
        name,
        content_type,
        bytes,
        sha256,
    })
}

/// Stores `bytes` and records an emoji named after `raw_name`.
///
/// `raw_name` is normalised here rather than by the caller, so `:Big Smile:`
/// and `:big_smile:` cannot both exist and then disagree about which one a
/// message meant. `uploader` is `None` for an import, which no account
/// performed.
///
/// The content type is sniffed from the bytes and never from a filename or a
/// declared header, and the bytes land in the same content-addressed blob a
/// message attachment would, so an image already present costs no second copy.
///
/// A refusal writes nothing. The cap and the name are checked before the bytes
/// are, rather than by deleting them afterwards, because a compensating delete
/// cannot be made safe here: the blob and its `attachments` row are addressed
/// by content, so an image already attached to a message (or held by another
/// emoji) lives at exactly the path and row a refused upload of the same bytes
/// would want to remove, and a delete can fail on its own besides. What a
/// pre-check cannot do is bind: two uploads can both read a count below the cap
/// and both go on to write, so [`Store::create_custom_emoji`] checks again in
/// its transaction and is what actually holds the cap. The loser of that race
/// leaves behind an upload nothing references, which is the ordinary shape
/// `Store::sweep_orphaned_attachments` already reclaims, bytes and row
/// together.
pub async fn add_emoji(
    store: &Store,
    media: &Media,
    raw_name: &str,
    bytes: Vec<u8>,
    uploader: Option<UserId>,
) -> Result<CustomEmoji, AddError> {
    let image = validate_image(raw_name, bytes)?;

    if let Some(refusal) = store
        .custom_emoji_refusal(&image.name)
        .await
        .map_err(AddError::Storage)?
    {
        return Err(refused(refusal));
    }

    let hex_id = media::to_hex(&image.sha256);
    let size = image.bytes.len() as i64;

    // Bytes before the metadata row, the same ordering attachments uses: a
    // row pointing at bytes that are not there yet is the worse failure.
    media
        .write_attachment(&hex_id, image.bytes)
        .await
        .map_err(|err| AddError::Storage(err.into()))?;
    store
        .store_attachment(
            &image.sha256,
            size,
            image.content_type,
            &format!("{}.img", image.name),
            uploader,
        )
        .await
        .map_err(AddError::Storage)?;

    let created = store
        .create_custom_emoji(EmojiId::generate(), &image.name, &image.sha256, uploader)
        .await
        .map_err(AddError::Storage)?;

    created.map_err(refused)
}

/// The one place a store-level refusal becomes an [`AddError`], so the check
/// made before the bytes are written and the check the transaction makes
/// cannot answer the same refusal differently.
pub(crate) fn refused(err: CreateEmojiError) -> AddError {
    match err {
        CreateEmojiError::NameTaken => AddError::NameTaken,
        CreateEmojiError::Full => AddError::Full,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_name_is_reduced_to_what_can_be_typed_between_colons() {
        assert_eq!(normalize_name("Big Smile").as_deref(), Ok("big_smile"));
        assert_eq!(
            normalize_name("party-parrot").as_deref(),
            Ok("party_parrot")
        );
        assert_eq!(normalize_name("  OK  ").as_deref(), Ok("ok"));
        assert_eq!(
            normalize_name(":::").as_deref(),
            Err(&NameProblem::Unusable)
        );
        assert_eq!(normalize_name("").as_deref(), Err(&NameProblem::Unusable));
    }

    /// A name of legal characters that is merely long is a different failure
    /// from one with no legal characters at all, and the caller has to be able
    /// to tell them apart to report either honestly.
    #[test]
    fn a_long_name_fails_for_its_length_rather_than_its_characters() {
        assert_eq!(
            normalize_name(&"x".repeat(MAX_NAME_LEN + 1)),
            Err(NameProblem::TooLong {
                length: MAX_NAME_LEN + 1
            })
        );
        assert!(
            normalize_name(&"x".repeat(MAX_NAME_LEN)).is_ok(),
            "the cap itself fits"
        );

        // The length reported is the one left after normalising, not the raw
        // one: "A Long Name" is what has to fit, not "A Long Name.png".
        assert_eq!(
            normalize_name(&format!("  {}  ", "A B".repeat(15))),
            Err(NameProblem::TooLong { length: 45 })
        );
    }

    /// Two spellings of one name must not become two emoji, or a message
    /// saying `:big_smile:` has no single answer.
    #[test]
    fn spellings_that_normalize_together_collide_rather_than_coexisting() {
        assert_eq!(normalize_name("Big Smile"), normalize_name("big-smile"));
    }

    /// The import normalises a filename before looking for a collision, then
    /// hands the result to `add_emoji`, which normalises again. That is only
    /// sound if a second pass is a no-op.
    #[test]
    fn normalising_an_already_normalised_name_changes_nothing() {
        for raw in ["Big Smile", "party-parrot", "  OK  ", "a1_b2"] {
            let once = normalize_name(raw).expect("usable");
            assert_eq!(normalize_name(&once).as_deref(), Ok(once.as_str()));
        }
    }
}
