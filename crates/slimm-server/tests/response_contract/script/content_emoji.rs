// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Custom emoji calls for `content.rs`, a sibling module rather than folded
//! into that already near-the-limit file - `content.rs` was past the
//! 500-line hard cap with this inline.

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use serde_json::json;

use super::{PNG, text};
use crate::world::{Contract, Payload};

/// The deployment's own emoji: add one, list it, bulk-add two more, fetch its
/// bytes, remove it.
///
/// Uses the same PNG as `content.rs`'s own attachment on purpose - the bytes
/// are content-addressed and shared, so this also exercises the case where
/// an emoji points at a hash a message already references.
pub(super) async fn emoji_calls(c: &mut Contract, root: &str) {
    let created = c
        .call(
            "uploadCustomEmoji",
            "POST",
            "/emoji?name=party_parrot",
            Some(root),
            Payload::Bytes(PNG.to_vec()),
        )
        .await;
    let id = text(&created, "id");

    c.get("listCustomEmoji", "/emoji", root).await;

    let mut second_png = PNG.to_vec();
    second_png.push(5);
    c.json(
        "bulkUploadCustomEmoji",
        "POST",
        "/emoji/bulk",
        root,
        json!({
            "images": [
                {"name": "bulk_one", "data": BASE64.encode(PNG)},
                {"name": "bulk_two", "data": BASE64.encode(&second_png)},
            ],
        }),
    )
    .await;

    c.call(
        "fetchCustomEmojiImage",
        "GET",
        &format!("/emoji/{id}/image"),
        Some(root),
        Payload::None,
    )
    .await;
    // A gif emoji is served as the type sniffed from its bytes, not as png.
    let mut gif = b"GIF89a".to_vec();
    gif.extend([0u8; 8]);
    let animated = c
        .call(
            "uploadCustomEmoji",
            "POST",
            "/emoji?name=party_gif",
            Some(root),
            Payload::Bytes(gif),
        )
        .await;
    c.call(
        "fetchCustomEmojiImage",
        "GET",
        &format!("/emoji/{}/image", text(&animated, "id")),
        Some(root),
        Payload::None,
    )
    .await;
    c.call(
        "deleteCustomEmoji",
        "DELETE",
        &format!("/emoji/{id}"),
        Some(root),
        Payload::None,
    )
    .await;
}
