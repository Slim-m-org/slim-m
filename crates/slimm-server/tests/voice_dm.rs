// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Calling someone in a DM: `POST /channels/{id}/voice/token` for a
//! `dm`-kind channel, gated by nothing but [`Store::dm_permissions`] - see
//! `store/dms.rs`'s `DM_BASE` and `BLOCKED_DENY`. No new route, no schema
//! change: the leverage is the same the module doc already claims for
//! sending, sync and search, extended to cover voice.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD as BASE64URL;
use serde_json::Value;
use slimm_server::auth::Auth;
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::Store;
use slimm_server::voice::VoiceService;
use tower::ServiceExt;

mod support;

fn app(store: Store, voice: VoiceService) -> Router {
    http::router(AppState {
        store,
        auth: Auth::new(2).unwrap(),
        hub: Hub::new(),
        limiter: RateLimiter::new(),
        push: PushSender::disabled(),
        voice,
        media: slimm_server::media::Media::for_tests(),
        gifs: slimm_server::http::gifs::GifSearch::disabled(),
        link_previews: slimm_server::http::link_preview::LinkPreviews::disabled(),
        dock: slimm_server::http::dock::Dock::disabled(),
        code_runner: slimm_server::code_runner::CodeRunner::disabled(),
    })
}

fn enabled_voice() -> VoiceService {
    VoiceService::for_test(
        "wss://livekit.example.com",
        "APItestkey",
        "a-test-secret-of-at-least-32-characters",
    )
}

fn request(method: &str, uri: &str, token: Option<&str>) -> Request<Body> {
    let mut builder = Request::builder().method(method).uri(uri);
    if let Some(token) = token {
        builder = builder.header("authorization", format!("Bearer {token}"));
    }
    builder.body(Body::empty()).unwrap()
}

async fn json_body(response: axum::response::Response) -> Value {
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    serde_json::from_slice(&bytes).unwrap()
}

fn claims_of(token: &str) -> Value {
    let payload = token.split('.').nth(1).expect("a jwt has three parts");
    serde_json::from_slice(&BASE64URL.decode(payload).expect("base64url")).expect("json")
}

/// A member with a session, built straight through the store; the first one
/// through claims the deployment, matching `tests/dms.rs`'s own helper.
async fn register(store: &Store, username: &str) -> (String, String) {
    let account = store
        .create_account(username, username, "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    let tokens = store.open_session(account.id, "cli").await.unwrap();
    (tokens.access_token, account.id.to_string())
}

async fn open_dm(app: &Router, token: &str, target_id: &str) -> String {
    let response = app
        .clone()
        .oneshot(request("POST", &format!("/dms/{target_id}"), Some(token)))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    json_body(response).await["channel_id"]
        .as_str()
        .unwrap()
        .to_owned()
}

async fn block(app: &Router, token: &str, target_id: &str) -> StatusCode {
    app.clone()
        .oneshot(request(
            "POST",
            &format!("/blocks/{target_id}"),
            Some(token),
        ))
        .await
        .unwrap()
        .status()
}

async fn voice_token(app: &Router, channel_id: &str, token: &str) -> axum::response::Response {
    app.clone()
        .oneshot(request(
            "POST",
            &format!("/channels/{channel_id}/voice/token"),
            Some(token),
        ))
        .await
        .unwrap()
}

/// The deliverable: two people in a DM can both mint a token for its voice
/// room, and each gets one that can publish - a DM call has no listen-only
/// side, unlike a moderated channel where `SPEAK` can be withheld.
#[tokio::test]
async fn either_dm_participant_can_start_or_join_a_call() {
    let (store, _guard) = support::new_store("slimm-voice-dm-test").await;
    let app = app(store.clone(), enabled_voice());

    let (alice_token, _alice_id) = register(&store, "alice").await;
    let (bob_token, bob_id) = register(&store, "bob").await;
    let channel_id = open_dm(&app, &alice_token, &bob_id).await;

    let starter = voice_token(&app, &channel_id, &alice_token).await;
    assert_eq!(starter.status(), StatusCode::OK);
    let starter_body = json_body(starter).await;
    assert_eq!(starter_body["can_publish"], true);
    assert_eq!(
        claims_of(starter_body["token"].as_str().unwrap())["video"]["room"],
        format!("channel-{channel_id}")
    );

    let joiner = voice_token(&app, &channel_id, &bob_token).await;
    assert_eq!(joiner.status(), StatusCode::OK);
    assert_eq!(json_body(joiner).await["can_publish"], true);
}

/// A DM is between exactly its two participants; a third account must not be
/// able to mint a token for a call it was never part of, the same
/// containment `administrator_who_is_not_a_participant_cannot_read_or_send_in_a_dm`
/// already proves for reading and sending.
#[tokio::test]
async fn a_non_participant_cannot_mint_a_token_for_someone_elses_dm() {
    let (store, _guard) = support::new_store("slimm-voice-dm-test").await;
    let app = app(store.clone(), enabled_voice());

    let (alice_token, _alice_id) = register(&store, "alice").await;
    let (_bob_token, bob_id) = register(&store, "bob").await;
    let (eve_token, _eve_id) = register(&store, "eve").await;
    let channel_id = open_dm(&app, &alice_token, &bob_id).await;

    let response = voice_token(&app, &channel_id, &eve_token).await;
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
}

/// The safety-critical case: a blocked person must not be able to ring the
/// person who blocked them, and the blocker must not be able to ring back
/// either - `BLOCKED_DENY` removes `CONNECT` for both directions, mirroring
/// how it already removes `SEND_MESSAGES`.
#[tokio::test]
async fn blocking_refuses_a_voice_token_in_either_direction() {
    let (store, _guard) = support::new_store("slimm-voice-dm-test").await;
    let app = app(store.clone(), enabled_voice());

    let (alice_token, _alice_id) = register(&store, "alice").await;
    let (bob_token, bob_id) = register(&store, "bob").await;
    let channel_id = open_dm(&app, &alice_token, &bob_id).await;

    // Before the block, both directions still work.
    assert_eq!(
        voice_token(&app, &channel_id, &alice_token).await.status(),
        StatusCode::OK
    );
    assert_eq!(
        voice_token(&app, &channel_id, &bob_token).await.status(),
        StatusCode::OK
    );

    assert_eq!(
        block(&app, &alice_token, &bob_id).await,
        StatusCode::NO_CONTENT
    );

    assert_eq!(
        voice_token(&app, &channel_id, &bob_token).await.status(),
        StatusCode::FORBIDDEN,
        "the blocked party must not be able to ring the person who blocked them"
    );
    assert_eq!(
        voice_token(&app, &channel_id, &alice_token).await.status(),
        StatusCode::FORBIDDEN,
        "the blocker must not be able to call back either"
    );
}

/// The roster preview (`GET .../voice/roster`) is gated on `VIEW_CHANNEL`
/// alone, which a DM participant already held before this change; a
/// non-participant must still be refused. Run against a deployment with no
/// SFU so the assertion is purely about the permission gate in front of it.
#[tokio::test]
async fn dm_voice_roster_is_reachable_only_to_participants() {
    let (store, _guard) = support::new_store("slimm-voice-dm-test").await;
    let app = app(store.clone(), VoiceService::disabled());

    let (alice_token, _alice_id) = register(&store, "alice").await;
    let (_bob_token, bob_id) = register(&store, "bob").await;
    let (eve_token, _eve_id) = register(&store, "eve").await;
    let channel_id = open_dm(&app, &alice_token, &bob_id).await;

    let participant = app
        .clone()
        .oneshot(request(
            "GET",
            &format!("/channels/{channel_id}/voice/roster"),
            Some(&alice_token),
        ))
        .await
        .unwrap();
    assert_eq!(
        participant.status(),
        StatusCode::NOT_IMPLEMENTED,
        "the permission gate passes; only the missing SFU stops it"
    );

    let stranger = app
        .clone()
        .oneshot(request(
            "GET",
            &format!("/channels/{channel_id}/voice/roster"),
            Some(&eve_token),
        ))
        .await
        .unwrap();
    assert_eq!(stranger.status(), StatusCode::FORBIDDEN);
}
