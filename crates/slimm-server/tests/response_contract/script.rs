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
mod space_banner;
mod space_icon;
mod threads;
mod totp_calls;
mod upload_sessions;
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
use space_banner::banner_calls;
use space_icon::icon_calls;
use threads::thread_calls;
use upload_sessions::upload_session_calls;

const PASSWORD: &str = "a-long-enough-password";
/// A 16x16 PNG's signature and header chunks, which is all the server reads of an upload.
pub(super) const PNG: [u8; 57] = [
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x10, 0x08, 0x06, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x49, 0x44, 0x41, 0x54, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x49, 0x45, 0x4E, 0x44, 0x00, 0x00, 0x00, 0x00,
];
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

    banner_calls(c, root, &code).await;
    icon_calls(c, root, &code).await;
    upload_session_calls(c, root).await;
    c.bare("getSpaceSettings", "GET", "/space/settings", root)
        .await;
    // Set back to what it already is, so the rest of the pass still runs
    // against an invite-only deployment.
    c.json(
        "updateSpaceSettings",
        "PATCH",
        "/space/settings",
        root,
        json!({"join_policy": "invite", "welcome_message": "Welcome {user} to {space}"}),
    )
    .await;
    c.bare("getJoinGate", "GET", "/space/join-gate", root).await;
    // Left off, so nobody the rest of the pass registers waits behind it.
    let gate = json!({"enabled": false, "rules": "be kind", "rules_channel_id": null, "joins_paused": false});
    c.json("putJoinGate", "PUT", "/space/join-gate", root, gate)
        .await;
    c.bare("getSpaceRules", "GET", "/space/rules", root).await;
    c.bare("acceptSpaceRules", "POST", "/space/rules/accept", root)
        .await;

    // Off by default, exercising the `stats: null` branch before it is on.
    c.bare("getSpaceAnalytics", "GET", "/space/analytics", root)
        .await;

    c.bare("getSpaceRetention", "GET", "/space/retention", root)
        .await;
    c.bare(
        "previewSpaceRetention",
        "GET",
        "/space/retention/preview?days=30",
        root,
    )
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

    c.bare("getSpaceLinkPreviews", "GET", "/space/link-previews", root)
        .await;
    c.json(
        "updateSpaceLinkPreviews",
        "PATCH",
        "/space/link-previews",
        root,
        json!({"enabled": false}),
    )
    .await;
    // Back on, because later calls unfurl and embed images.
    c.json(
        "updateSpaceLinkPreviews",
        "PATCH",
        "/space/link-previews",
        root,
        json!({"enabled": true}),
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
    channel_retention_calls(c, root, &channel).await;
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
    c.bare("listAdminAuditLog", "GET", "/space/audit-log", root)
        .await;
    c.bare("listMyLinkedAccounts", "GET", "/me/links", bob_token)
        .await;
    c.bare(
        "listUserLinkedAccounts",
        "GET",
        &format!("/users/{bob_id}/links"),
        root,
    )
    .await;
    c.bare("unlinkDiscord", "DELETE", "/me/links/discord", bob_token)
        .await;

    c.json(
        "sync",
        "POST",
        "/sync",
        root,
        json!({ "scopes": [{ "channel_id": channel, "after_seq": 0 }] }),
    )
    .await;
    // A call in the history, so the shape checked is a populated one.
    let voice_channel = slimm_server::ids::ChannelId(channel.parse().unwrap());
    let caller = slimm_server::ids::UserId(admin_id.parse().unwrap());
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64;
    for (at, kind) in [
        (now - 2000, slimm_server::store::VoiceEventKind::Joined),
        (now - 1000, slimm_server::store::VoiceEventKind::Left),
    ] {
        c.state
            .store
            .record_voice_event(voice_channel, caller, kind, at)
            .await
            .unwrap();
    }
    c.get(
        "listVoiceCalls",
        &format!("/channels/{channel}/voice/calls"),
        root,
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

/// A channel's own retention, set and cleared again so the rest of the pass keeps following the Space.
async fn channel_retention_calls(c: &mut Contract, root: &str, channel: &str) {
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
