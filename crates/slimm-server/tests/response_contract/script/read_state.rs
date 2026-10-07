// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The read-state routes, in call order.
//!
//! Order is the point rather than an accident. `markUnread` runs after
//! `markRead` so its answer is a channel that has been read and marked unread
//! anyway - the state the flag exists to represent. Calling it first would
//! validate a response that looks the same as an ordinary unread channel and
//! prove nothing about the flag.
//!
//! Its own module because `content.rs` reached the review ceiling.

use serde_json::json;

use crate::world::Contract;

pub(crate) async fn read_state(c: &mut Contract, root: &str, channel: &str, seq: i64) {
    c.get("getReadState", &format!("/channels/{channel}/read"), root)
        .await;
    c.json(
        "markRead",
        "PUT",
        &format!("/channels/{channel}/read"),
        root,
        json!({ "seq": seq }),
    )
    .await;
    c.bare(
        "markUnread",
        "PUT",
        &format!("/channels/{channel}/unread"),
        root,
    )
    .await;
    c.get("listReadStates", "/read-states", root).await;
    c.json(
        "markChannelsRead",
        "POST",
        "/read-states/read",
        root,
        json!({ "channel_ids": [channel] }),
    )
    .await;
}
