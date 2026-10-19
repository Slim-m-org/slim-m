// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The half of the pass about people rather than content: the caller's own
//! profile and avatar, other users, presence, devices, blocks, and the
//! report queue.

use serde_json::json;

use super::{PNG, text};
use crate::world::{Contract, Payload};

pub(super) async fn profile_calls(c: &mut Contract, root: &str, admin_id: &str, bob_id: &str) {
    c.get("getMe", "/me", root).await;
    c.json(
        "updateMe",
        "PATCH",
        "/me",
        root,
        json!({ "display_name": "Admin" }),
    )
    .await;
    c.get(
        "listUsers",
        &format!("/users?ids={admin_id},{bob_id}"),
        root,
    )
    .await;
    c.get("getUser", &format!("/users/{bob_id}"), root).await;
    c.get("listMembers", "/members?limit=50", root).await;
    c.get(
        "listPresence",
        &format!("/presence?ids={admin_id},{bob_id}"),
        root,
    )
    .await;
    c.json(
        "setPresenceVisibility",
        "PATCH",
        "/presence",
        root,
        json!({ "visibility": "hidden" }),
    )
    .await;

    c.call(
        "uploadAvatar",
        "POST",
        "/me/avatar",
        Some(root),
        Payload::Bytes(PNG.to_vec()),
    )
    .await;
    c.get("getAvatar", &format!("/users/{admin_id}/avatar"), root)
        .await;
    c.bare("deleteAvatar", "DELETE", "/me/avatar", root).await;
    c.call(
        "uploadBanner",
        "POST",
        "/me/banner",
        Some(root),
        Payload::Bytes(PNG.to_vec()),
    )
    .await;
    c.get("getBanner", &format!("/users/{admin_id}/banner"), root)
        .await;
    c.bare("deleteBanner", "DELETE", "/me/banner", root).await;

    c.json(
        "setPresenceActivity",
        "PUT",
        "/presence/activity",
        root,
        json!({"type": "listening", "title": "Song", "subtitle": "Artist"}),
    )
    .await;
    c.bare(
        "clearPresenceActivity",
        "DELETE",
        "/presence/activity",
        root,
    )
    .await;
}

pub(super) async fn safety_calls(c: &mut Contract, root: &str, bob_token: &str, bob_id: &str) {
    let devices = c.get("listDevices", "/devices", bob_token).await;
    let other = devices
        .as_array()
        .and_then(|list| list.iter().find(|d| d["is_current"] == json!(false)))
        .map(|d| text(d, "id"))
        .expect("bob signed in twice, so one device is not the current one");
    c.bare(
        "removeDevice",
        "DELETE",
        &format!("/devices/{other}"),
        bob_token,
    )
    .await;

    c.json(
        "putUserNote",
        "PUT",
        &format!("/users/{bob_id}/note"),
        root,
        json!({ "body": "keep an eye on this one" }),
    )
    .await;
    c.get("getUserNote", &format!("/users/{bob_id}/note"), root)
        .await;

    c.bare("blockUser", "POST", &format!("/blocks/{bob_id}"), root)
        .await;
    c.get("listBlocks", "/blocks", root).await;
    c.bare("unblockUser", "DELETE", &format!("/blocks/{bob_id}"), root)
        .await;
}

pub(super) async fn moderation_calls(c: &mut Contract, root: &str, bob_token: &str, message: &str) {
    let report_id = uuid::Uuid::now_v7().to_string();
    let body = json!({
        "id": report_id,
        "subject_kind": "message",
        "subject_id": message,
        "reason": "spam"
    });
    let filed = c
        .json("fileReport", "POST", "/reports", bob_token, body.clone())
        .await;
    // The replay half of the contract: the same id answers with the same report.
    let replayed = c
        .json("fileReport", "POST", "/reports", bob_token, body)
        .await;
    assert_eq!(text(&replayed, "id"), text(&filed, "id"));
    c.get("listOpenReports", "/reports", root).await;
    c.get(
        "myReportStatus",
        &format!("/reports/mine/{}", text(&filed, "id")),
        bob_token,
    )
    .await;
    c.json(
        "resolveReport",
        "PATCH",
        &format!("/reports/{}", text(&filed, "id")),
        root,
        json!({ "resolution": "dismissed" }),
    )
    .await;
    // The report resolved above is now a `resolved_report` entry in the feed.
    c.get("moderationHistory", "/reports/history", root).await;
}
