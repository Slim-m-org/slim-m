// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Threads, split out of `content.rs` when that file crossed the 500-line
//! hard ceiling: open one on the channel's own message, resolve it back to
//! its parent, send a reply so `thread_reply_count`/`thread_last_reply_at`
//! exercise a real value, then list the channel's threads.

use serde_json::json;
use uuid::Uuid;

use super::text;
use crate::response_contract::world::Contract;

/// `channel` and `message` are `content::channel_calls`'s and
/// `content::message_calls`'s own return values - the message this opens a
/// thread on already carries an attachment, an edit, a poll, a reaction and
/// a pin by the time this runs.
pub(super) async fn thread_calls(c: &mut Contract, root: &str, channel: &str, message: &str) {
    let messages = format!("/channels/{channel}/messages");
    let thread = c
        .bare(
            "openThread",
            "POST",
            &format!("{messages}/{message}/thread"),
            root,
        )
        .await;
    let thread_id = text(&thread, "id");
    c.get(
        "getThreadParent",
        &format!("/channels/{thread_id}/thread-parent"),
        root,
    )
    .await;
    // A reply, so thread_reply_count/thread_last_reply_at below exercise a real value.
    c.json(
        "sendMessage",
        "POST",
        &format!("/channels/{thread_id}/messages"),
        root,
        json!({ "id": Uuid::now_v7().to_string(), "content": "first reply" }),
    )
    .await;
    c.get("listThreads", &format!("/channels/{channel}/threads"), root)
        .await;
}
