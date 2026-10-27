// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Push preferences, channel notification overrides, invites and channel retention.

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use serde_json::json;

use super::{notification_schedule_calls, text};
use crate::world::{Contract, Payload};

pub(super) async fn push_calls(c: &mut Contract, root: &str, channel: &str, bob_id: &str) {
    c.get("getNotificationPreference", "/push/preference", root)
        .await;
    c.json(
        "setNotificationPreference",
        "PUT",
        "/push/preference",
        root,
        json!({ "preference": "mentions" }),
    )
    .await;
    c.get("getPushPreview", "/push/preview", root).await;
    c.json(
        "setPushPreview",
        "PUT",
        "/push/preview",
        root,
        json!({ "include_content": false }),
    )
    .await;
    c.json(
        "registerPush",
        "PUT",
        "/push",
        root,
        json!({
            "platform": "ios",
            "push_token": "a-device-token",
            "voip_push_token": "a-voip-token",
            "push_public_key": BASE64.encode([7u8; 32]),
        }),
    )
    .await;
    c.json(
        "reportPushLifecycle",
        "PUT",
        "/push/lifecycle",
        root,
        json!({ "state": "background" }),
    )
    .await;
    channel_notification_override_calls(c, root, channel).await;
    c.get("getDirectRoute", "/direct-route", root).await;
    c.get("diagnosticsPing", "/diagnostics/ping", root).await;
    notification_schedule_calls::notification_schedule_calls(c, root, channel, bob_id).await;
    c.bare("deregisterPush", "DELETE", "/push", root).await;
}

/// Set, list, and clear a per-channel override, in that order so the list
/// call sees a real, non-empty answer rather than only the empty case.
async fn channel_notification_override_calls(c: &mut Contract, root: &str, channel: &str) {
    c.json(
        "setChannelNotificationOverride",
        "PUT",
        &format!("/notification-preferences/channels/{channel}"),
        root,
        json!({ "preference": "everything" }),
    )
    .await;
    c.get(
        "listChannelNotificationOverrides",
        "/notification-preferences/channels",
        root,
    )
    .await;
    c.bare(
        "clearChannelNotificationOverride",
        "DELETE",
        &format!("/notification-preferences/channels/{channel}"),
        root,
    )
    .await;
}

/// A second, unlimited code, so redeeming and revoking it cannot spend or
/// close the one the remaining registrations below still need. Checking this
/// one as well as the capped one above is what puts a null through the
/// optional halves of the invite preview.
pub(super) async fn invite_calls(c: &mut Contract, root: &str, bob_token: &str) {
    let spare = c
        .json("createInvite", "POST", "/invites", root, json!({}))
        .await;
    let spare = text(&spare, "code");
    c.call(
        "checkInvite",
        "GET",
        &format!("/invites/{spare}/check"),
        None,
        Payload::None,
    )
    .await;
    c.bare(
        "redeemInvite",
        "POST",
        &format!("/invites/{spare}/redeem"),
        bob_token,
    )
    .await;
    c.bare("revokeInvite", "DELETE", &format!("/invites/{spare}"), root)
        .await;
}

/// A channel's own retention, set and cleared again so the rest of the pass keeps following the Space.
pub(super) async fn channel_retention_calls(c: &mut Contract, root: &str, channel: &str) {
    let path = format!("/channels/{channel}/retention");
    c.get("getChannelRetention", &path, root).await;
    c.get(
        "previewChannelRetention",
        &format!("{path}/preview?days=30"),
        root,
    )
    .await;
    for days in [json!(30), json!(null)] {
        c.json(
            "updateChannelRetention",
            "PUT",
            &path,
            root,
            json!({ "retention_days": days }),
        )
        .await;
    }
}
