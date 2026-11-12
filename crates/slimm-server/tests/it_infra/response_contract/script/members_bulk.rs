// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The bulk halves of the member moderation verbs, a separate module for the
//! same reason `content_messages_window.rs` is: adding them inline pushed
//! `script.rs` past the 500-line hard cap.

use serde_json::json;

use crate::response_contract::world::Contract;

/// Times one member out and removes them through the bulk routes, then
/// restores them.
///
/// Driven against the same member the single-target calls above already use,
/// in the same order, so the two verbs are exercised for real rather than
/// listed as uncovered. The restore at the end matters: later calls in the
/// script still expect to find this member in the Space.
pub(super) async fn bulk_member_calls(c: &mut Contract, root: &str, erin_id: &str) {
    c.json(
        "bulkTimeoutMembers",
        "POST",
        "/members/bulk-timeout",
        root,
        json!({ "user_ids": [erin_id], "duration_seconds": 300 }),
    )
    .await;
    c.json(
        "bulkRemoveMembers",
        "POST",
        "/members/bulk-removal",
        root,
        json!({ "user_ids": [erin_id], "reason": "contract" }),
    )
    .await;
    c.bare(
        "restoreMember",
        "DELETE",
        &format!("/members/{erin_id}/removal"),
        root,
    )
    .await;
}
