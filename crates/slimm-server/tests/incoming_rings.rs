// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A client that connects after `call.ringing` was published can still ask
//! for its outstanding rings, and only its own.

use axum::Router;
use axum::http::StatusCode;
use serde_json::Value;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::hub::Hub;
use slimm_server::push::PushSender;
use slimm_server::store::Store;
use slimm_server::sweep_stale_call_rings_at;
use slimm_server::voice::{RING_TIMEOUT, VoiceService};
use tower::ServiceExt;

mod support;

use support::app::{json_body, register_token_id as register, request_bare as request};

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
    let app = support::app::builder(store.clone())
        .hub(hub.clone())
        .voice(voice.clone())
        .router();
    Harness {
        app,
        store,
        voice,
        hub,
        _guard: guard,
    }
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

/// Two people ringing each other: the second ring replaces the first, and the
/// first caller is told their ring ended rather than ringing out forever
/// (issue 2087).
#[tokio::test]
async fn a_ring_replaced_by_the_other_side_is_reported_ended() {
    let h = harness().await;
    let (alice_token, _alice_id) = register(&h.store, "alice").await;
    let (bob_token, bob_id) = register(&h.store, "bob").await;
    let channel_id = open_dm(&h.app, &alice_token, &bob_id).await;
    assert_eq!(
        ring(&h.app, &channel_id, &alice_token).await,
        StatusCode::OK
    );
    let alice_ring = rings_for(&h.app, &bob_token).await[0]["ring_id"]
        .as_str()
        .unwrap()
        .to_owned();
    let mut durable = h.hub.subscribe();
    let mut ephemeral = h.hub.subscribe_ephemeral();

    assert_eq!(ring(&h.app, &channel_id, &bob_token).await, StatusCode::OK);

    let mut ended = Vec::new();
    let mut records = 0;
    for rx in [&mut durable, &mut ephemeral] {
        while let Ok(event) = rx.try_recv() {
            match event {
                slimm_server::hub::Event::CallRingEnded {
                    ring_id, outcome, ..
                } => {
                    ended.push((ring_id.to_string(), outcome.as_str().to_owned()));
                }
                slimm_server::hub::Event::MessageCreated { call: Some(_), .. } => records += 1,
                _ => {}
            }
        }
    }
    assert_eq!(ended, vec![(alice_ring, "answered".to_owned())]);
    assert_eq!(
        records, 0,
        "ringing back is not a finished call, so it leaves no record"
    );
}
