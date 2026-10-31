// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The four group DM routes (decision 0095), a sibling of `content_dm_calls.rs`.

use serde_json::json;

use crate::world::Contract;

/// Root starts a group with bob and carol, renames it, adds dave, and bob leaves.
pub(super) async fn group_dm_calls(c: &mut Contract, root: &str, bob_token: &str, bob_id: &str) {
    let (_, carol_id) = crate::support::app::register_token_id(&c.state.store, "grp-carol").await;
    let (_, dave_id) = crate::support::app::register_token_id(&c.state.store, "grp-dave").await;
    let created = c
        .json(
            "createGroupDirectMessage",
            "POST",
            "/dms/groups",
            root,
            json!({ "user_ids": [bob_id, carol_id] }),
        )
        .await;
    let channel = created["channel_id"].as_str().expect("channel id");
    c.json(
        "renameGroupDirectMessage",
        "PATCH",
        &format!("/dms/groups/{channel}"),
        root,
        json!({ "name": "trip" }),
    )
    .await;
    c.json(
        "addGroupDirectMessageMember",
        "POST",
        &format!("/dms/groups/{channel}/members"),
        root,
        json!({ "user_id": dave_id }),
    )
    .await;
    c.bare(
        "leaveGroupDirectMessage",
        "POST",
        &format!("/dms/groups/{channel}/leave"),
        bob_token,
    )
    .await;
}
