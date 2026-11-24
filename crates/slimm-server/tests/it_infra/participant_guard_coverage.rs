// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Every mutating authenticated route takes the participant guard or says why it needs none:
//! a timeout and the join gate otherwise reach only the routes that check a permission bit.

#![allow(dead_code)]

use std::collections::BTreeSet;
use std::path::Path;

use crate::openapi_429_coverage::{HandlerFn, functions_in, resolve_handler};
use crate::support;
use support::code_only;
use support::openapi::{Method, RouterRoute, extract_router_routes};

/// Fewer mutating authenticated routes than this means the walk stopped short.
const MIN_ROUTES: usize = 200;

/// Routes that need no guard, grouped by the one reason each group shares.
const EXEMPT: &[(&str, &[&str])] = &[
    (
        "Own account, device and preference self-service that only the caller, or a moderator reading a report, ever sees",
        &[
            "POST /auth/ws-ticket",
            "POST /auth/logout",
            "DELETE /account",
            "POST /auth/password",
            "POST /auth/totp/enrol",
            "POST /auth/totp/confirm",
            "POST /auth/totp/recovery-codes",
            "POST /auth/totp/disable",
            "DELETE /devices/{device_id}",
            "PUT /push",
            "DELETE /push",
            "PUT /push/lifecycle",
            "PUT /push/preference",
            "PUT /push/preview",
            "PUT /notification-preferences/channels/{channel_id}",
            "DELETE /notification-preferences/channels/{channel_id}",
            "PUT /notification-preferences/categories/{category_id}",
            "DELETE /notification-preferences/categories/{category_id}",
            "PUT /voice-notifications/channels/{channel_id}",
            "PUT /notifications/schedule",
            "DELETE /notifications/schedule",
            "PUT /notifications/schedule/allowed-users/{user_id}",
            "DELETE /notifications/schedule/allowed-users/{user_id}",
            "PUT /notifications/schedule/allowed-channels/{channel_id}",
            "DELETE /notifications/schedule/allowed-channels/{channel_id}",
            "PUT /notifications/schedule/snooze",
            "DELETE /notifications/schedule/snooze",
            "POST /favorites",
            "PUT /favorites/order",
            "DELETE /favorites/{favorite_id}",
            "POST /favorites/{favorite_id}/select",
            "PUT /messages/{message_id}/save",
            "DELETE /messages/{message_id}/save",
            "PUT /users/{user_id}/note",
            "POST /read-states/read",
            "PUT /channels/{channel_id}/read",
            "PUT /channels/{channel_id}/unread",
            "POST /sync",
            "POST /blocks/{user_id}",
            "DELETE /blocks/{user_id}",
            "POST /reports",
            "PATCH /presence",
            "PUT /me/hold-music",
            "POST /exports/member",
            "DELETE /exports/{export_id}",
            "DELETE /dms/{user_id}",
            "POST /voice/transcription-notice/ack",
            "POST /me/links/steam/start",
            "POST /me/links/steam/complete",
            "DELETE /me/links/steam",
            "PUT /me/links/steam/sharing",
            "POST /me/links/discord/start",
            "POST /me/links/discord/complete",
            "DELETE /me/links/discord",
            "POST /space/rules/accept",
        ],
    ),
    (
        "Withdrawing or stopping what the caller already put out, which a hold must never strand",
        &[
            "DELETE /invites/{code}",
            "DELETE /channels/{channel_id}/messages/{message_id}",
            "DELETE /presence/activity",
            "DELETE /me/avatar",
            "DELETE /me/banner",
            "DELETE /messages/{message_id}/reactions/{emoji}",
            "DELETE /attachments/uploads/{upload_id}",
            "DELETE /channels/{channel_id}/voice/heartbeat",
            "PUT /channels/{channel_id}/voice/deafened",
            "PUT /channels/{channel_id}/voice/muted",
            "POST /channels/{channel_id}/voice/ring/decline",
            "POST /dms/groups/{channel_id}/leave",
            "DELETE /channels/{channel_id}/voice/call-audio",
            "DELETE /channels/{channelId}/watch-session",
        ],
    ),
    (
        "Content checked against SEND_MESSAGES, ATTACH_FILES, ADD_REACTIONS, CONNECT or SPEAK, which both holds subtract",
        &[
            "POST /channels/{channel_id}/messages",
            "PATCH /channels/{channel_id}/messages/{message_id}",
            "POST /channels/{channel_id}/messages/polls",
            "PUT /messages/{message_id}/polls/vote",
            "PUT /messages/{message_id}/reactions/{emoji}",
            "POST /channels/{channel_id}/messages/{message_id}/thread",
            "POST /channels/{channelId}/ephemeral-messages",
            "PUT /channels/{channelId}/messages/{messageId}/components",
            "POST /channels/{channel_id}/messages/apps",
            "DELETE /channels/{channel_id}/messages/{message_id}/link-previews",
            "POST /attachments",
            "POST /attachments/uploads",
            "PUT /attachments/uploads/{upload_id}",
            "POST /attachments/uploads/{upload_id}/complete",
            "POST /gifs/select",
            "POST /channels/{channel_id}/voice/screen-stamps",
            "POST /channels/{channel_id}/voice/token",
            "POST /channels/{channel_id}/voice/heartbeat",
            "POST /channels/{channel_id}/voice/ring",
            "POST /channels/{channel_id}/voice/room",
            "POST /channels/{channel_id}/voice/soundboard/{clip_id}/play",
            "POST /channels/{channel_id}/module-rooms/{module_id}/inputs",
        ],
    ),
    (
        "Canvas writes: USE_CANVAS or MANAGE_CANVAS, which the gate subtracts; drawing also checks the timeout itself",
        &[
            "POST /channels/{channel_id}/canvas/objects",
            "POST /channels/{channel_id}/canvas/objects/batch",
            "POST /channels/{channel_id}/canvas/ops",
            "PUT /channels/{channel_id}/canvas/media-slots/{kind}/{user_id}",
            "PUT /channels/{channel_id}/canvas/objects/{object_id}/lock",
            "DELETE /channels/{channel_id}/canvas/objects/{object_id}/lock",
            "DELETE /channels/{channel_id}/canvas/objects/{object_id}",
        ],
    ),
    (
        "Administration and moderation on a MANAGE_*, KICK, BAN or ADMINISTRATOR bit: the gate subtracts it, and a timeout leaves administration alone by design",
        &[
            "PUT /space/alerts/mute",
            "PATCH /space/analytics",
            "PATCH /space/retention",
            "PATCH /space/canvas-cap",
            "PATCH /space/screen-share",
            "PATCH /space/attachment-limit",
            "PATCH /space/media-compression",
            "PATCH /space/link-previews",
            "PATCH /space/settings",
            "POST /space/banner",
            "DELETE /space/banner",
            "POST /space/icon",
            "DELETE /space/icon",
            "POST /space/setup/complete",
            "DELETE /space/themes/{theme_id}",
            "PUT /space/default-theme",
            "PUT /space/join-gate",
            "POST /space/uplink-test",
            "POST /bots/{bot_id}/revoke",
            "PATCH /bots/{bot_id}/permissions",
            "PATCH /bots/{bot_id}/prefix",
            "POST /categories",
            "PATCH /categories/{category_id}",
            "DELETE /categories/{category_id}",
            "PUT /categories/order",
            "PUT /categories/{category_id}/overwrites",
            "POST /channels/{channel_id}/overwrites/sync",
            "POST /categories/{category_id}/overwrites/sync",
            "PUT /channels/order",
            "PUT /channels/{channel_id}/retention",
            "POST /channels",
            "PATCH /channels/{channel_id}",
            "DELETE /channels/{channel_id}",
            "PUT /channels/{channel_id}/overwrites",
            "PUT /channels/{channel_id}/overwrites/{kind}/{id}",
            "DELETE /channels/{channel_id}/overwrites/{kind}/{id}",
            "PUT /channels/{channel_id}/messages/{message_id}/pin",
            "DELETE /channels/{channel_id}/messages/{message_id}/pin",
            "POST /channels/{channel_id}/messages/bulk-delete",
            "POST /channels/{channel_id}/messages/bulk-delete-by-author",
            "POST /exports/space",
            "DELETE /debug-logs/{id}",
            "POST /space/dock/packages/preview",
            "POST /space/dock/packages/install",
            "POST /space/dock/modules/{id}/install",
            "DELETE /space/dock/modules/{id}/install",
            "DELETE /space/dock/modules/{id}/storage",
            "POST /space/dock/modules/{id}/enable",
            "POST /space/dock/modules/{id}/disable",
            "POST /space/dock/sources",
            "DELETE /space/dock/sources/{sourceId}",
            "PUT /space/dock/modules/{id}/settings",
            "PUT /space/dock/modules/{id}/call-audio-channels",
            "PUT /space/dock/modules/{id}/hooks",
            "PUT /space/dock/modules/{id}/schedule-channel",
            "PUT /roles/{role_id}/module-permissions/{module_id}/{perm_key}",
            "DELETE /roles/{role_id}/module-permissions/{module_id}/{perm_key}",
            "POST /emoji",
            "DELETE /emoji/{emoji_id}",
            "POST /emoji/bulk",
            "PUT /members/{user_id}/nickname",
            "DELETE /members/{user_id}/nickname",
            "POST /members/bulk-removal",
            "POST /members/bulk-timeout",
            "PUT /members/{user_id}/timeout",
            "DELETE /members/{user_id}/timeout",
            "PUT /members/{user_id}/removal",
            "DELETE /members/{user_id}/removal",
            "DELETE /members/{user_id}/account",
            "POST /admin/users/{user_id}/reset-code",
            "DELETE /admin/users/{user_id}/totp",
            "PATCH /reports/{report_id}",
            "PATCH /roles/reorder",
            "POST /roles",
            "PATCH /roles/{role_id}",
            "DELETE /roles/{role_id}",
            "PUT /members/{user_id}/roles/{role_id}",
            "DELETE /members/{user_id}/roles/{role_id}",
            "POST /soundboard",
            "PATCH /soundboard/{clip_id}",
            "DELETE /soundboard/{clip_id}",
            "POST /channels/{channel_id}/voice/participants/{user_id}/kick",
            "POST /channels/{channel_id}/voice/participants/{user_id}/move",
            "DELETE /voice/transcripts/{transcript_id}",
            "DELETE /voice/transcripts/{transcript_id}/marks/{mark_id}",
            "POST /webhooks",
            "PATCH /webhooks/{webhook_id}",
            "POST /webhooks/{webhook_id}/rotate",
            "POST /webhooks/{webhook_id}/revoke",
        ],
    ),
    (
        "A bot's own registration, hidden from members while it is timed out, or an acknowledgement that shows nothing",
        &[
            "PUT /bots/ui",
            "PUT /bots/commands",
            "POST /channels/{channelId}/interactions/{interactionId}/ack",
        ],
    ),
    (
        "Spending an invite: a timeout and the join gate still subtract from any role it gives, and sign-in redeems one before the rules are accepted",
        &["POST /invites/{code}/redeem"],
    ),
    (
        "Not yet decided: each needs its own policy and is left to a later change",
        &[
            "POST /connectors/me/runs/{runId}",
            "PUT /channels/{channelId}/watch-session/viewing",
            "POST /channels/{channelId}/watch-session/tick",
            "PUT /channels/{channelId}/watch-session",
            "POST /dms/{user_id}",
            "POST /dms/groups",
            "PATCH /dms/groups/{channel_id}",
            "DELETE /dms/groups/{channel_id}",
            "POST /dms/groups/{channel_id}/members",
            "POST /space/themes",
            "PATCH /channels/{channel_id}/room",
            "POST /diagnostics/upload",
            "POST /channels/{channel_id}/voice/call-audio",
            "PUT /channels/{channel_id}/voice/call-audio/consent",
            "POST /channels/{channel_id}/voice/transcript",
            "PUT /voice/transcripts/{transcript_id}/marks/{mark_id}",
        ],
    ),
];

/// The extractor, or one of the holds it is made of when a route applies only one.
fn guarded(handler: &HandlerFn) -> bool {
    handler.signature.contains("Participant<")
        || [
            "require_participant(",
            "require_admitted(",
            "require_not_timed_out(",
        ]
        .iter()
        .any(|call| handler.body.contains(call))
}

fn authenticated(handler: &HandlerFn) -> bool {
    let sig = &handler.signature;
    sig.contains(": Authed,")
        || sig.contains(": Authed)")
        || [
            "AuthedLimited<",
            "ManagerLimited<",
            "ConnectorLimited<",
            "Participant<",
        ]
        .iter()
        .any(|extractor| sig.contains(extractor))
}

fn mutating(route: &RouterRoute) -> bool {
    !matches!(
        route.method,
        Method::Get | Method::Head | Method::Options | Method::Trace
    )
}

fn label(route: &RouterRoute) -> String {
    format!("{} {}", route.method.as_str(), route.path)
}

/// Every mutating authenticated route, as `"METHOD /path"`, paired with whether it is guarded.
fn mutating_routes() -> Vec<(String, bool)> {
    let manifest_dir = Path::new(env!("CARGO_MANIFEST_DIR"));
    extract_router_routes(manifest_dir)
        .iter()
        .filter(|route| mutating(route))
        .filter_map(|route| {
            let (_, handler) = resolve_handler(manifest_dir, route)
                .unwrap_or_else(|| panic!("{} could not be resolved", label(route)));
            authenticated(&handler).then(|| (label(route), guarded(&handler)))
        })
        .collect()
}

fn exempt() -> BTreeSet<&'static str> {
    let mut seen = BTreeSet::new();
    for (_, routes) in EXEMPT {
        for route in *routes {
            assert!(seen.insert(*route), "{route} is exempted twice");
        }
    }
    seen
}

#[test]
fn every_mutating_route_takes_the_participant_guard_or_an_exemption() {
    let routes = mutating_routes();
    assert!(
        routes.len() >= MIN_ROUTES,
        "only {} routes found",
        routes.len()
    );
    let exempt = exempt();
    let unguarded: Vec<&str> = routes
        .iter()
        .filter(|(route, guarded)| !guarded && !exempt.contains(route.as_str()))
        .map(|(route, _)| route.as_str())
        .collect();
    assert!(
        unguarded.is_empty(),
        "these routes check neither a timeout nor the join gate; take Participant<C>, call \
         require_admitted or require_not_timed_out, or add them to EXEMPT under a reason:\n  {}",
        unguarded.join("\n  ")
    );
}

#[test]
fn every_exemption_names_a_live_unguarded_route() {
    let routes = mutating_routes();
    let stale: Vec<&str> = exempt()
        .into_iter()
        .filter(|exempted| {
            !routes
                .iter()
                .any(|(route, guarded)| route == exempted && !guarded)
        })
        .collect();
    assert!(
        stale.is_empty(),
        "these exemptions name no unguarded mutating route; drop them:\n  {}",
        stale.join("\n  ")
    );
}

#[test]
fn the_gate_tells_a_guarded_handler_from_one_that_only_mentions_the_guard() {
    let sample = r#"
async fn by_extractor(Participant(ctx): Participant<WRITE>) -> Result<(), ApiError> { Ok(()) }

async fn by_hold(Authed(ctx): Authed, parts: Parts) -> Result<(), ApiError> {
    require_not_timed_out(&state, ctx.user_id).await?;
    Ok(())
}

/// Should call require_admitted(...) but does not.
async fn unguarded(Authed(ctx): Authed) -> Result<(), ApiError> {
    let note = "require_participant(";
    Ok(())
}
"#;
    let fns = functions_in(&code_only(sample));
    assert!(guarded(&fns["by_extractor"]));
    assert!(guarded(&fns["by_hold"]));
    assert!(
        !guarded(&fns["unguarded"]),
        "a comment or string is not a guard"
    );
    assert!(fns.values().all(authenticated));
}
