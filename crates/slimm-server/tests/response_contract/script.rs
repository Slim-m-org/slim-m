// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! One pass over the whole documented surface, in dependency order: claim the
//! deployment, invite a second account, then build the channel, message,
//! attachment, poll, pin and reaction state each later call needs.
//!
//! Ordering is not incidental. Reactions, an attachment and a poll are all in
//! place before `listMessages` and `sync` run, so the `Message` shape those
//! two validate is the fully populated one rather than a bare text row; and
//! the account-destroying calls (`logout`, `deleteAccount`, `resetPassword`)
//! run last, against accounts nothing else still needs.

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use serde_json::{Value, json};

use super::world::{Contract, Payload};

mod admin_recovery;
mod bots;
mod content;
mod content_dm_calls;
mod content_emoji;
mod content_media_slots;
mod content_messages_window;
mod content_roles;
mod dock;
mod farewell;
mod gifs;
mod link_preview;
mod member_account;
mod members_bulk;
mod notification_schedule_calls;
mod people;
mod read_state;
mod refusals;
mod threads;
mod totp_calls;
mod webhooks;

use content::{channel_calls, message_calls};
use content_dm_calls::dm_call_ring_calls;
use content_emoji::emoji_calls;
use content_media_slots::{media_slot_calls, object_lock_calls};
use content_messages_window::bulk_delete_by_author_call;
use content_roles::{overwrite_calls, role_calls};
use dock::dock_calls;
use farewell::farewell_calls;
use gifs::gif_calls;
use link_preview::link_preview_calls;
use people::{moderation_calls, profile_calls, safety_calls};
use threads::thread_calls;

const PASSWORD: &str = "a-long-enough-password";
/// A PNG header is all the server's content sniffing looks at.
pub(super) const PNG: [u8; 12] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4];
pub(super) const THUMBS_UP: &str = "%F0%9F%91%8D";

pub(super) fn text(value: &Value, field: &str) -> String {
    value[field]
        .as_str()
        .unwrap_or_else(|| panic!("expected a string `{field}` in {value}"))
        .to_owned()
}

pub(super) fn signup(username: &str, device: &str, invite: Option<&str>) -> Value {
    json!({
        "username": username,
        "display_name": username,
        "password": PASSWORD,
        "device_name": device,
        "invite_code": invite,
    })
}

pub async fn run(c: &mut Contract) {
    c.call("getHealth", "GET", "/healthz", None, Payload::None)
        .await;
    c.call("getVersion", "GET", "/version", None, Payload::None)
        .await;

    // The first account through registration claims the deployment and is its
    // administrator, so everything below that needs a privilege has one.
    let admin = c
        .call(
            "register",
            "POST",
            "/auth/register",
            None,
            Payload::Json(signup("admin", "laptop", None)),
        )
        .await;
    let admin_token = text(&admin, "access_token");
    let root = admin_token.as_str();
    let admin_id = text(&admin, "user_id");

    let invite = c
        .json(
            "createInvite",
            "POST",
            "/invites",
            root,
            json!({ "max_uses": 6 }),
        )
        .await;
    let code = text(&invite, "code");
    c.get("listInvites", "/invites", root).await;
    c.call(
        "checkInvite",
        "GET",
        &format!("/invites/{code}/check"),
        None,
        Payload::None,
    )
    .await;

    let bob = c
        .call(
            "register",
            "POST",
            "/auth/register",
            None,
            Payload::Json(signup("bob", "phone", Some(&code))),
        )
        .await;
    let bob_access = text(&bob, "access_token");
    let bob_token = bob_access.as_str();
    let bob_id = text(&bob, "user_id");

    let second = c
        .call(
            "login",
            "POST",
            "/auth/login",
            None,
            Payload::Json(json!({
                "username": "bob", "password": PASSWORD, "device_name": "tablet"
            })),
        )
        .await;
    c.call(
        "refresh",
        "POST",
        "/auth/refresh",
        None,
        Payload::Json(json!({ "refresh_token": text(&second, "refresh_token") })),
    )
    .await;
    c.bare("createWsTicket", "POST", "/auth/ws-ticket", root)
        .await;

    c.bare("getSpaceSettings", "GET", "/space/settings", root)
        .await;
    // Set back to what it already is, so the rest of the pass still runs
    // against an invite-only deployment.
    c.json(
        "updateSpaceSettings",
        "PATCH",
        "/space/settings",
        root,
        json!({"join_policy": "invite"}),
    )
    .await;

    // Off by default, exercising the `stats: null` branch before it is on.
    c.bare("getSpaceAnalytics", "GET", "/space/analytics", root)
        .await;

    c.bare("getSpaceRetention", "GET", "/space/retention", root)
        .await;
    // Set back to disabled, so the rest of the pass keeps its own history.
    c.json(
        "updateSpaceRetention",
        "PATCH",
        "/space/retention",
        root,
        json!({"retention_days": 30}),
    )
    .await;
    c.json(
        "updateSpaceRetention",
        "PATCH",
        "/space/retention",
        root,
        json!({"retention_days": 0}),
    )
    .await;

    c.bare("getSpaceCanvasCap", "GET", "/space/canvas-cap", root)
        .await;
    // Change it and set it back, so the rest of the pass keeps the default.
    c.json(
        "updateSpaceCanvasCap",
        "PATCH",
        "/space/canvas-cap",
        root,
        json!({"object_cap": 5000}),
    )
    .await;
    c.json(
        "updateSpaceCanvasCap",
        "PATCH",
        "/space/canvas-cap",
        root,
        json!({"object_cap": 20000}),
    )
    .await;

    c.bare("getSpaceScreenShareCap", "GET", "/space/screen-share", root)
        .await;
    // Change it and set it back, so the rest of the pass keeps the default.
    c.json(
        "updateSpaceScreenShareCap",
        "PATCH",
        "/space/screen-share",
        root,
        json!({"max_height": 720}),
    )
    .await;
    c.json(
        "updateSpaceScreenShareCap",
        "PATCH",
        "/space/screen-share",
        root,
        json!({"max_height": 2160}),
    )
    .await;

    profile_calls(c, root, &admin_id, &bob_id).await;
    safety_calls(c, root, bob_token, &bob_id).await;

    let (channel, dm_channel) = channel_calls(c, root, &bob_id).await;
    dm_call_ring_calls(c, root, bob_token, &dm_channel).await;
    gif_calls(c, root).await;
    let upstream = c.upstream.clone();
    link_preview_calls(c, root, &upstream).await;
    dock_calls(c, root, &admin_id, &channel).await;
    let message = message_calls(c, root, &channel).await;
    bulk_delete_by_author_call(c, root, bob_token, &bob_id, &channel).await;
    thread_calls(c, root, &channel, &message).await;
    emoji_calls(c, root).await;
    moderation_calls(c, root, bob_token, &message).await;

    // Turned on after real history exists, so `stats` is populated, not zeros.
    c.json(
        "updateSpaceAnalytics",
        "PATCH",
        "/space/analytics",
        root,
        json!({"enabled": true}),
    )
    .await;

    c.bare("getSpaceStorage", "GET", "/space/storage", root)
        .await;

    c.json(
        "sync",
        "POST",
        "/sync",
        root,
        json!({ "scopes": [{ "channel_id": channel, "after_seq": 0 }] }),
    )
    .await;
    c.bare(
        "mintVoiceToken",
        "POST",
        &format!("/channels/{channel}/voice/token"),
        root,
    )
    .await;
    c.bare(
        "sendVoiceHeartbeat",
        "POST",
        &format!("/channels/{channel}/voice/heartbeat"),
        root,
    )
    .await;
    c.bare(
        "forgetVoiceHeartbeat",
        "DELETE",
        &format!("/channels/{channel}/voice/heartbeat"),
        root,
    )
    .await;

    push_calls(c, root, &channel, &bob_id).await;
    invite_calls(c, root, bob_token).await;
    // Last: a refusal leaves no state behind.
    refusals::refusal_calls(c, bob_token, &admin_id, &code).await;
    farewell_calls(c, root, &bob_id, &code, &channel).await;
}

async fn push_calls(c: &mut Contract, root: &str, channel: &str, bob_id: &str) {
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
    quiet_hours_calls(c, root).await;
    notification_schedule_calls::notification_schedule_calls(c, root, channel, bob_id).await;
    c.bare("deregisterPush", "DELETE", "/push", root).await;
}

/// Set, read, and clear the account-wide quiet-hours window, in that order
/// so the read call sees a real window rather than only the disabled case.
async fn quiet_hours_calls(c: &mut Contract, root: &str) {
    c.json(
        "setQuietHours",
        "PUT",
        "/push/quiet-hours",
        root,
        json!({ "start_minute": 23 * 60, "end_minute": 8 * 60 }),
    )
    .await;
    c.get("getQuietHours", "/push/quiet-hours", root).await;
    c.bare("clearQuietHours", "DELETE", "/push/quiet-hours", root)
        .await;
}

/// Set, list, and clear a per-channel override, in that order so the list
/// call sees a real, non-empty answer rather than only the empty case.
async fn channel_notification_override_calls(c: &mut Contract, root: &str, channel: &str) {
    c.json(
        "setChannelNotificationOverride",
        "PUT",
        &format!("/notification-preferences/channels/{channel}"),
        root,
        json!({ "preference": "nothing" }),
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
async fn invite_calls(c: &mut Contract, root: &str, bob_token: &str) {
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
