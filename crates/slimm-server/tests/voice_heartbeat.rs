// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `POST .../voice/heartbeat`: the route a live call refreshes so a
//! terminated app's ghost participant is bounded rather than left to
//! whatever the SFU's own reconnect grace period happens to be.
//!
//! The staleness arithmetic itself (a fresh heartbeat survives, a stopped one
//! goes stale, a refresh resets the clock) is unit-tested directly against
//! `CallHeartbeats` in `src/voice/heartbeat.rs`; this file is only the route:
//! that it is gated the same way minting a token is, and that it actually
//! reaches the tracker rather than just answering 204. Split into its own
//! file because `tests/voice.rs` was already past the file-size budget.

use axum::Router;
use axum::http::StatusCode;
use slimm_server::ids::{ChannelId, UserId};
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use slimm_server::voice::VoiceService;
use tower::ServiceExt;

mod support;

use support::app::request_bare as request;

fn app(store: Store, voice: VoiceService) -> Router {
    support::app::builder(store).voice(voice).router()
}

fn enabled_voice() -> VoiceService {
    VoiceService::for_test(
        "wss://livekit.example.com",
        "APItestkey",
        "a-test-secret-of-at-least-32-characters",
    )
}

async fn member(store: &Store, username: &str) -> (UserId, String) {
    let account = store
        .create_account(username, username, "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    let session = store.open_session(account.id, "cli").await.unwrap();
    (account.id, session.access_token)
}

/// The route actually has to reach the tracker, not just answer 204: a
/// handler that returns success without calling `record_heartbeat_reporting_new`
/// would pass every status-code assertion in this file and still leave a
/// terminated app's ghost participant unbounded.
#[tokio::test]
async fn a_heartbeat_is_recorded_against_the_caller_and_channel() {
    let (store, _guard) = support::new_store("slimm-voice-heartbeat-test").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::CONNECT),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let voice = enabled_voice();
    let (user_id, token) = member(&store, "alice").await;
    let app = app(store.clone(), voice.clone());

    assert!(!voice.has_heartbeat(user_id, channel.id));

    let response = app
        .oneshot(request(
            "POST",
            &format!("/channels/{}/voice/heartbeat", channel.id),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);
    assert!(voice.has_heartbeat(user_id, channel.id));
}

/// A routine keepalive from somebody already in the room answers nothing.
///
/// `heartbeat` claims an outstanding ring before recording the join, so that
/// the ring sweep cannot take it in between. That moved the claim out from
/// behind the first-join check, and without a gate every keepalive - one
/// every 15 seconds for as long as a call lasts - would try to answer. A
/// caller hanging up and ringing straight back while the callee is still in
/// the room would then have that ring answered by the callee's own
/// background timer, with the callee never seeing it, and an explicit
/// Decline would be racing their own keepalive.
#[tokio::test]
async fn a_keepalive_from_someone_already_in_the_call_does_not_answer_a_ring() {
    let (store, _guard) = support::new_store("slimm-voice-heartbeat-test").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::CONNECT),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let voice = enabled_voice();
    let (callee_id, callee_token) = member(&store, "bob").await;
    let (caller_id, _caller_token) = member(&store, "alice").await;
    let app = app(store.clone(), voice.clone());

    let beat = || {
        app.clone().oneshot(request(
            "POST",
            &format!("/channels/{}/voice/heartbeat", channel.id),
            Some(&callee_token),
        ))
    };

    // Bob is already in the call before any ring exists.
    assert_eq!(beat().await.unwrap().status(), StatusCode::NO_CONTENT);
    assert!(voice.has_heartbeat(callee_id, channel.id));

    let ring_id = voice.rings().start(channel.id, caller_id, callee_id).0;

    // His next routine keepalive must leave that ring outstanding.
    assert_eq!(beat().await.unwrap().status(), StatusCode::NO_CONTENT);
    assert_eq!(
        voice
            .rings()
            .answer(channel.id, callee_id)
            .map(|(id, _)| id),
        Some(ring_id),
        "the keepalive answered the ring; only a first join may do that"
    );
}

#[tokio::test]
async fn a_heartbeat_without_connect_is_refused() {
    let (store, _guard) = support::new_store("slimm-voice-heartbeat-test").await;
    // @everyone can see the channel but not connect to it.
    store
        .create_role("everyone", Permissions::VIEW_CHANNEL, true)
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let voice = enabled_voice();
    let (user_id, token) = member(&store, "alice").await;
    let app = app(store.clone(), voice.clone());

    let response = app
        .oneshot(request(
            "POST",
            &format!("/channels/{}/voice/heartbeat", channel.id),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
    assert!(!voice.has_heartbeat(user_id, channel.id));
}

#[tokio::test]
async fn a_heartbeat_requires_authentication() {
    let (store, _guard) = support::new_store("slimm-voice-heartbeat-test").await;
    let channel = store.create_channel("general", "text").await.unwrap();
    let app = app(store, enabled_voice());

    let response = app
        .oneshot(request(
            "POST",
            &format!("/channels/{}/voice/heartbeat", channel.id),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn a_heartbeat_on_a_text_only_deployment_says_so_instead_of_pretending() {
    let (store, _guard) = support::new_store("slimm-voice-heartbeat-test").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::CONNECT),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    // No SFU configured, which is a supported way to run this.
    let app = app(store.clone(), VoiceService::disabled());
    let (_, token) = member(&store, "alice").await;

    let response = app
        .oneshot(request(
            "POST",
            &format!("/channels/{}/voice/heartbeat", channel.id),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NOT_IMPLEMENTED);
}

/// The evaluator already covers precedence; this pins that the route reads
/// the per-channel answer rather than the base one, matching `voice.rs`'s own
/// `a_channel_denying_connect_beats_the_role_that_grants_it`.
#[tokio::test]
async fn a_channel_denying_connect_beats_the_role_that_grants_it() {
    let (store, _guard) = support::new_store("slimm-voice-heartbeat-test").await;
    let everyone = store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::CONNECT),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    store
        .set_role_overwrite(
            channel.id,
            everyone,
            Permissions::NONE,
            Permissions::CONNECT,
        )
        .await
        .unwrap();
    let voice = enabled_voice();
    let (user_id, token) = member(&store, "alice").await;
    let app = app(store.clone(), voice.clone());

    let response = app
        .oneshot(request(
            "POST",
            &format!("/channels/{}/voice/heartbeat", channel.id),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
    assert!(!voice.has_heartbeat(user_id, channel.id));
}

/// A nonexistent channel must refuse identically to one the caller may not
/// join, so its existence is not observable through this route either.
#[tokio::test]
async fn a_channel_that_does_not_exist_refuses_like_one_you_cannot_join() {
    let (store, _guard) = support::new_store("slimm-voice-heartbeat-test").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::CONNECT),
            true,
        )
        .await
        .unwrap();
    store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone(), enabled_voice());
    let (_, token) = member(&store, "alice").await;

    let missing = ChannelId(uuid::Uuid::now_v7());
    let response = app
        .oneshot(request(
            "POST",
            &format!("/channels/{missing}/voice/heartbeat"),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
}
