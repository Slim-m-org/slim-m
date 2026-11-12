// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The window-select sibling of `bulkDeleteMessages`'s call in `content.rs`,
//! a separate module for the same reason `content_media_slots.rs` is: folding
//! it into `message_calls` pushed `content.rs` past the 500-line hard cap.

use serde_json::json;
use uuid::Uuid;

use crate::response_contract::world::Contract;

/// Driven by a different author (bob) than `bulkDeleteMessages`'s own call in
/// `message_calls`, so it cannot collaterally delete the message or the poll
/// that function sent, which later calls in the script still need live.
pub(super) async fn bulk_delete_by_author_call(
    c: &mut Contract,
    root: &str,
    bob_token: &str,
    bob_id: &str,
    channel: &str,
) {
    let messages = format!("/channels/{channel}/messages");
    for _ in 0..2 {
        let body = json!({ "id": Uuid::now_v7().to_string(), "content": "raid spam by window" });
        c.json("sendMessage", "POST", &messages, bob_token, body)
            .await;
    }
    let bulk_by_author = format!("{messages}/bulk-delete-by-author");
    let window = json!({ "author_id": bob_id, "window_minutes": 60 });
    c.json(
        "bulkDeleteMessagesByAuthor",
        "POST",
        &bulk_by_author,
        root,
        window,
    )
    .await;
}
