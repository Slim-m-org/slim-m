// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Creating several emoji from one authenticated request.
//!
//! An admin importing a pack of images was hitting `POST /emoji` once per
//! image, which charges `Class::Upload` once per image too: a 200-image pack
//! exhausted that budget after ten and refused the other hundred and ninety,
//! one 429 per file. `Class::Upload` is deliberately tight - each request can
//! cost real megabytes of disk - and a bulk import is not 200 unrelated
//! uploads, it is one admin-authorized act that happens to carry 200 images.
//! This module is the shape that charges it as one: `http::emoji` charges
//! [`crate::ratelimit::Class::Upload`] exactly once per call here, however
//! many images the request carries.
//!
//! Bounded three ways, so an admin-authorized bulk act cannot become a bigger
//! bug than the one it replaces: [`MAX_BULK_IMAGES`] caps how many images one
//! call may carry, [`MAX_BULK_TOTAL_BYTES`] caps their total decoded size (both
//! enforced by `http::emoji` before it decodes the request), and
//! every image still passes [`super::validate_image`] - the exact rule
//! [`super::add_emoji`] enforces one at a time, run here before a single byte
//! is written.
//!
//! Validated as a whole, written as a whole: every image is checked before
//! any of them touch the store, and [`crate::store::Store::create_custom_emoji_batch`]
//! creates all of the rows in one transaction, so a batch that fails partway
//! (a bad image, a name collision) leaves none of it behind rather than the
//! first few. That is `messages_bulk`'s own rule, applied here: a caller
//! reasons about one request as one act, not as a sequence that might stop
//! anywhere.
//!
//! Distinct from [`super::import`], the operator's directory importer: that
//! one visits a directory unattended and reports each file's own fate since
//! nobody is present to react to a partial refusal. This instead answers one
//! HTTP request from an admin who is present, can read a single reason, and
//! can retry with a narrower batch - so all-or-nothing is the more useful
//! answer here, not the importer's skip-and-continue.

use super::{AddError, ValidatedImage, refused, validate_image};
use crate::ids::{EmojiId, UserId};
use crate::media::{self, Media};
use crate::store::{CustomEmoji, Store};

/// Most images one bulk-create call may carry.
///
/// Bounds the size of the single transaction [`Store::create_custom_emoji_batch`]
/// opens and the number of blob writes one request can trigger. A pack larger
/// than this chunks into more than one call - the rate-limit budget this
/// module exists to fix charges by the call, not by the image, so a few extra
/// calls for an unusually large pack costs nothing that matters.
pub const MAX_BULK_IMAGES: usize = 50;

/// Most decoded image bytes one bulk-create call's images may total.
///
/// The per-image cap ([`super::MAX_IMAGE_BYTES`], 1 MiB) already bounds any
/// one image; this bounds the request as a whole so [`MAX_BULK_IMAGES`]
/// worth of maximally-sized images cannot turn one call into a 50 MiB write.
/// 20 MiB comfortably covers a real pack (emoji images are typically tens of
/// kilobytes, not the ceiling) while keeping the request body, and the
/// memory it costs to hold every image before the batch's transaction opens,
/// well short of that worst case.
pub const MAX_BULK_TOTAL_BYTES: u64 = 20 * 1024 * 1024;

/// Why a bulk create was refused. The batch-wide limits are the caller's to
/// enforce before it decodes anything; only a per-image refusal or a storage
/// failure can come back from here.
#[derive(Debug)]
pub enum BulkAddError {
    /// The image at this index failed the same check [`super::add_emoji`]
    /// would refuse it for, including a name already taken - by another
    /// image earlier in this same batch, or by an existing emoji.
    Item { index: usize, error: AddError },
    /// The database or the blob directory refused the write.
    Storage(anyhow::Error),
}

/// Validates every `(raw_name, bytes)` pair in `items`, then creates them all
/// as one act, or none of them.
///
/// Does not enforce [`MAX_BULK_IMAGES`] or [`MAX_BULK_TOTAL_BYTES`]: the one
/// caller, `http::emoji`, checks both before it has decoded the request.
///
/// Validation - name, size, content type, and no two items sharing a
/// normalised name - runs over the whole list before any bytes are written,
/// the same rule [`crate::store::message_authors_in`] documents for bulk
/// message deletion: an item this caller may not add must not leave an
/// earlier item in the same call already stored while the call as a whole
/// fails.
///
/// Bytes and `attachments` rows are still written per image before the
/// batch's own transaction opens, the same ordering and the same accepted
/// race [`super::add_emoji`] documents: if the transaction that follows then
/// rolls back (a name collision, a lost race against the cap), those blobs
/// are left referenced by nothing and the orphan sweep reclaims them, same as
/// a refused single upload's would.
pub async fn add_emoji_bulk(
    store: &Store,
    media: &Media,
    items: Vec<(String, Vec<u8>)>,
    uploader: Option<UserId>,
) -> Result<Vec<CustomEmoji>, BulkAddError> {
    let mut validated: Vec<ValidatedImage> = Vec::with_capacity(items.len());
    for (index, (raw_name, bytes)) in items.into_iter().enumerate() {
        let image = validate_image(&raw_name, bytes)
            .map_err(|error| BulkAddError::Item { index, error })?;
        if validated.iter().any(|v| v.name == image.name) {
            return Err(BulkAddError::Item {
                index,
                error: AddError::NameTaken,
            });
        }
        validated.push(image);
    }
    if validated.is_empty() {
        return Ok(Vec::new());
    }

    for image in &validated {
        let hex_id = media::to_hex(&image.sha256);
        media
            .write_attachment(&hex_id, image.bytes.clone())
            .await
            .map_err(|err| BulkAddError::Storage(err.into()))?;
        store
            .store_attachment(
                &image.sha256,
                image.bytes.len() as i64,
                image.content_type,
                &format!("{}.img", image.name),
                uploader,
            )
            .await
            .map_err(BulkAddError::Storage)?;
    }

    let rows: Vec<(EmojiId, String, Vec<u8>)> = validated
        .into_iter()
        .map(|image| (EmojiId::generate(), image.name, image.sha256))
        .collect();

    let outcome = store
        .create_custom_emoji_batch(rows, uploader)
        .await
        .map_err(BulkAddError::Storage)?;

    outcome.map_err(|(index, err)| BulkAddError::Item {
        index,
        error: refused(err),
    })
}
