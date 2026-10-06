// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A client that connects after `call.ringing` was published can still ask
//! for its outstanding rings, and only its own.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::Value;
use slimm_server::auth::Auth;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::Store;
use slimm_server::sweep_stale_call_rings_at;
use slimm_server::voice::{RING_TIMEOUT, VoiceService};
use tower::ServiceExt;

mod support;

struct Harness {
    app: Router,
    store: Store,
    voice: VoiceService,
    hub: Hub,
    _guard: support::TestDbGuard,
}

async fn harness() -> Harness {
    let (path, guard) = support::TestDbGuard::new("slimm-incoming-rings-test");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    let store = Store::new(pool);
    let voice = VoiceService::for_test(
        "wss://livekit.example.com",
        "APItestkey",
        "a-test-secret-of-at-least-32-characters",
    );
    let hub = Hub::new();
    let app = http::router(AppState {
        store: store.clone(),
        auth: Auth::new(2).unwrap(),
        hub: hub.clone(),
        limiter: RateLimiter::new(),
        push: PushSender::disabled(),
        voice: voice.clone(),
        media: slimm_server::media::Media::for_tests(),
        gifs: slimm_server::http::gifs::GifSearch::disabled(),
        link_previews: slimm_server::http::link_preview::LinkPreviews::disabled(),
        dock: slimm_server::http::dock::Dock::disabled(),
        code_runner: slimm_server::code_runner::CodeRunner::disabled(),
    });
    Harness {
        app,
        store,
        voice,
        hub,
        _guard: guard,
    }
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

async fn ring(app: &Router, channel_id: &str, token: &str) -> StatusCode {
    app.clone()
        .oneshot(request(
            "POST",
            &format!("/channels/{channel_id}/voice/ring"),
            Some(token),
        ))
        .await
        .unwrap()
        .status()
}

async fn incoming(app: &Router, token: Option<&str>) -> (StatusCode, Value) {
    let response = app
        .clone()
        .oneshot(request("GET", "/voice/rings/incoming", token))
        .await
        .unwrap();
    let status = response.status();
    if status != StatusCode::OK {
        return (status, Value::Null);
    }
    (status, json_body(response).await)
}

async fn rings_for(app: &Router, token: &str) -> Vec<Value> {
    let (status, body) = incoming(app, Some(token)).await;
    assert_eq!(status, StatusCode::OK);
    body["rings"].as_array().unwrap().clone()
}

/// The cold-launch case: the ring was published before this client existed.
#[tokio::test]
async fn the_callee_can_read_an_outstanding_ring_after_the_frame_was_missed() {
    let h = harness().await;
    let (alice_token, alice_id) = register(&h.store, "alice").await;
    let (bob_token, bob_id) = register(&h.store, "bob").await;
    let channel_id = open_dm(&h.app, &alice_token, &bob_id).await;
    assert_eq!(
        ring(&h.app, &channel_id, &alice_token).await,
        StatusCode::OK
    );

    let rings = rings_for(&h.app, &bob_token).await;
    assert_eq!(rings.len(), 1);
    assert_eq!(rings[0]["channel_id"], channel_id);
    assert_eq!(rings[0]["caller_id"], alice_id);
    assert!(rings[0]["ring_id"].as_str().is_some());
    let left = rings[0]["remaining_ms"].as_i64().unwrap();
    assert!(left > 0 && left <= RING_TIMEOUT.as_millis() as i64);
}

/// A ring is private to its recipient: the caller and a bystander see none.
#[tokio::test]
async fn a_ring_is_never_listed_to_anyone_but_its_callee() {
    let h = harness().await;
    let (alice_token, _alice_id) = register(&h.store, "alice").await;
    let (_bob_token, bob_id) = register(&h.store, "bob").await;
    let (carol_token, _carol_id) = register(&h.store, "carol").await;
    let channel_id = open_dm(&h.app, &alice_token, &bob_id).await;
    assert_eq!(
        ring(&h.app, &channel_id, &alice_token).await,
        StatusCode::OK
    );

    assert!(rings_for(&h.app, &alice_token).await.is_empty());
    assert!(rings_for(&h.app, &carol_token).await.is_empty());
}

#[tokio::test]
async fn a_declined_or_timed_out_ring_is_no_longer_listed() {
    let h = harness().await;
    let (alice_token, _alice_id) = register(&h.store, "alice").await;
    let (bob_token, bob_id) = register(&h.store, "bob").await;
    let channel_id = open_dm(&h.app, &alice_token, &bob_id).await;

    assert_eq!(
        ring(&h.app, &channel_id, &alice_token).await,
        StatusCode::OK
    );
    let declined = h
        .app
        .clone()
        .oneshot(request(
            "POST",
            &format!("/channels/{channel_id}/voice/ring/decline"),
            Some(&bob_token),
        ))
        .await
        .unwrap();
    assert_eq!(declined.status(), StatusCode::NO_CONTENT);
    assert!(rings_for(&h.app, &bob_token).await.is_empty());

    assert_eq!(
        ring(&h.app, &channel_id, &alice_token).await,
        StatusCode::OK
    );
    sweep_stale_call_rings_at(
        &h.voice,
        &h.hub,
        &h.store,
        &PushSender::disabled(),
        std::time::Instant::now() + RING_TIMEOUT,
    )
    .await;
    assert!(rings_for(&h.app, &bob_token).await.is_empty());
}

#[tokio::test]
async fn listing_rings_needs_a_session() {
    let h = harness().await;
    let (status, _) = incoming(&h.app, None).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
}
