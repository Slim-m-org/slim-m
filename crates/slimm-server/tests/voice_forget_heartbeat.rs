// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `DELETE .../voice/heartbeat`: the route a clean leave calls so the server
//! drops a caller's heartbeat entry immediately, rather than the sweep
//! rediscovering it stale and evicting a participant who already
//! disconnected on their own. Split into its own file for the same reason
//! `voice_heartbeat.rs` was split from `voice.rs`: keeps each under budget.

use axum::Router;
use axum::http::StatusCode;
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

async fn member(store: &Store, username: &str) -> (slimm_server::ids::UserId, String) {
    let account = store
        .create_account(username, username, "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    let session = store.open_session(account.id, "cli").await.unwrap();
    (account.id, session.access_token)
}

#[tokio::test]
async fn forgetting_a_recorded_heartbeat_drops_it() {
    let (store, _guard) = support::new_store("slimm-voice-forget-heartbeat-test").await;
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

    app.clone()
        .oneshot(request(
            "POST",
            &format!("/channels/{}/voice/heartbeat", channel.id),
            Some(&token),
        ))
        .await
        .unwrap();
    assert!(voice.has_heartbeat(user_id, channel.id));

    let response = app
        .oneshot(request(
            "DELETE",
            &format!("/channels/{}/voice/heartbeat", channel.id),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);
    assert!(!voice.has_heartbeat(user_id, channel.id));
}

#[tokio::test]
async fn forgetting_a_heartbeat_never_recorded_is_a_harmless_no_op() {
    let (store, _guard) = support::new_store("slimm-voice-forget-heartbeat-test").await;
    let channel = store.create_channel("general", "text").await.unwrap();
    let (_, token) = member(&store, "alice").await;
    let app = app(store.clone(), enabled_voice());

    let response = app
        .oneshot(request(
            "DELETE",
            &format!("/channels/{}/voice/heartbeat", channel.id),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);
}

#[tokio::test]
async fn forgetting_a_heartbeat_requires_authentication() {
    let (store, _guard) = support::new_store("slimm-voice-forget-heartbeat-test").await;
    let channel = store.create_channel("general", "text").await.unwrap();
    let app = app(store, enabled_voice());

    let response = app
        .oneshot(request(
            "DELETE",
            &format!("/channels/{}/voice/heartbeat", channel.id),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
}

/// Unlike every other voice route, no CONNECT (or any other permission) is
/// needed: the caller has nothing to gain by forgetting their own marker
/// early, and a permission revoked mid-call must not be what blocks a
/// client's own cleanup.
#[tokio::test]
async fn forgetting_a_heartbeat_needs_no_permission_at_all() {
    let (store, _guard) = support::new_store("slimm-voice-forget-heartbeat-test").await;
    store
        .create_role("everyone", Permissions::NONE, true)
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let (_, token) = member(&store, "alice").await;
    let app = app(store.clone(), enabled_voice());

    let response = app
        .oneshot(request(
            "DELETE",
            &format!("/channels/{}/voice/heartbeat", channel.id),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);
}

/// A deployment with no SFU configured still accepts this: there is nothing
/// to configure for a purely local map removal, so refusing it would be a
/// distinction with no purpose.
#[tokio::test]
async fn forgetting_a_heartbeat_on_a_text_only_deployment_still_succeeds() {
    let (store, _guard) = support::new_store("slimm-voice-forget-heartbeat-test").await;
    let channel = store.create_channel("general", "text").await.unwrap();
    let (_, token) = member(&store, "alice").await;
    let app = app(store.clone(), VoiceService::disabled());

    let response = app
        .oneshot(request(
            "DELETE",
            &format!("/channels/{}/voice/heartbeat", channel.id),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);
}

/// A malformed channel id is still a 400: the route reads it before deciding
/// there is nothing else to check.
#[tokio::test]
async fn forgetting_a_heartbeat_for_a_malformed_channel_id_is_a_bad_request() {
    let (store, _guard) = support::new_store("slimm-voice-forget-heartbeat-test").await;
    let (_, token) = member(&store, "alice").await;
    let app = app(store.clone(), enabled_voice());

    let response = app
        .oneshot(request(
            "DELETE",
            "/channels/not-a-uuid/voice/heartbeat",
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}
