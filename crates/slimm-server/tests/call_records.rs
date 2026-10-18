// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A DM call leaves a record in the transcript, whatever it ended as.
//!
//! The case worth the whole feature is the one nobody answered: before this,
//! every part of ringing was ephemeral - the ring lives in memory, the sweep
//! tears it down after the timeout, and nothing was written - so a missed call
//! was invisible to the person who missed it. The timed-out test below is
//! therefore the one that matters; the others exist so the three outcomes that
//! *do* have a live event cannot quietly stop recording.

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
    let (path, guard) = support::TestDbGuard::new("slimm-call-records-test");
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

/// Every call record in a channel, read the way a client reads them: off the
/// ordinary message list, not a route of its own.
async fn calls_in(app: &Router, channel_id: &str, token: &str) -> Vec<Value> {
    let response = app
        .clone()
        .oneshot(request(
            "GET",
            &format!("/channels/{channel_id}/messages"),
            Some(token),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    json_body(response)
        .await
        .as_array()
        .unwrap()
        .iter()
        .filter(|m| !m["call"].is_null())
        .cloned()
        .collect()
}

/// The deliverable. Alice rings, nobody answers, the sweep gives up - and the
/// DM now says so, where before it said nothing at all.
#[tokio::test]
async fn a_call_nobody_answered_leaves_a_record_in_the_dm() {
    let h = harness().await;
    let (alice_token, _alice_id) = register(&h.store, "alice").await;
    let (bob_token, bob_id) = register(&h.store, "bob").await;
    let channel_id = open_dm(&h.app, &alice_token, &bob_id).await;

    assert_eq!(
        ring(&h.app, &channel_id, &alice_token).await,
        StatusCode::OK
    );
    assert!(
        calls_in(&h.app, &channel_id, &bob_token).await.is_empty(),
        "a ring still in progress is not yet a record of anything"
    );

    sweep_stale_call_rings_at(
        &h.voice,
        &h.hub,
        &h.store,
        &PushSender::disabled(),
        std::time::Instant::now() + RING_TIMEOUT,
    )
    .await;

    let calls = calls_in(&h.app, &channel_id, &bob_token).await;
    assert_eq!(
        calls.len(),
        1,
        "the missed call must be in bob's transcript"
    );
    assert_eq!(calls[0]["call"]["outcome"], "timed_out");
    assert!(
        calls[0]["call"]["duration_ms"].is_null(),
        "nothing lasted any time when nobody picked up"
    );
    assert_eq!(
        calls[0]["content"], "",
        "the wording is the client's; storage must not freeze one reading"
    );
}

/// Declining is the other way a call does not happen, and the person who
/// declined should still see it in their own transcript afterwards.
#[tokio::test]
async fn a_declined_call_is_recorded_too() {
    let h = harness().await;
    let (alice_token, alice_id) = register(&h.store, "alice").await;
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

    let calls = calls_in(&h.app, &channel_id, &alice_token).await;
    assert_eq!(calls.len(), 1);
    assert_eq!(calls[0]["call"]["outcome"], "declined");
    assert_eq!(
        calls[0]["call"]["caller_id"], alice_id,
        "a declined call is still attributed to whoever placed it"
    );
}

/// Ringing twice and missing twice must leave two records, not one that keeps
/// being rewritten - the transcript is a history, not a status.
#[tokio::test]
async fn each_missed_call_is_its_own_record() {
    let h = harness().await;
    let (alice_token, _alice_id) = register(&h.store, "alice").await;
    let (bob_token, bob_id) = register(&h.store, "bob").await;
    let channel_id = open_dm(&h.app, &alice_token, &bob_id).await;

    for _ in 0..2 {
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
    }

    assert_eq!(calls_in(&h.app, &channel_id, &bob_token).await.len(), 2);
}

/// Answering is the callee's first heartbeat for the channel, not a route of
/// its own, so the record for a call that happened is written from inside the
/// heartbeat handler - the one write site with nothing named "ring" in it.
#[tokio::test]
async fn an_answered_call_is_recorded_when_the_callee_first_joins() {
    let h = harness().await;
    let (alice_token, alice_id) = register(&h.store, "alice").await;
    let (bob_token, bob_id) = register(&h.store, "bob").await;
    let channel_id = open_dm(&h.app, &alice_token, &bob_id).await;

    assert_eq!(
        ring(&h.app, &channel_id, &alice_token).await,
        StatusCode::OK
    );
    let joined = h
        .app
        .clone()
        .oneshot(request(
            "POST",
            &format!("/channels/{channel_id}/voice/heartbeat"),
            Some(&bob_token),
        ))
        .await
        .unwrap();
    assert_eq!(joined.status(), StatusCode::NO_CONTENT);

    let calls = calls_in(&h.app, &channel_id, &bob_token).await;
    assert_eq!(
        calls.len(),
        1,
        "bob answering must leave exactly one record"
    );
    assert_eq!(calls[0]["call"]["outcome"], "answered");
    assert_eq!(
        calls[0]["call"]["caller_id"], alice_id,
        "an answered call is attributed to whoever placed it, not who answered"
    );
    assert!(
        calls[0]["call"]["duration_ms"].is_null(),
        "how long it ran is not known at the moment it is answered"
    );

    // A routine keepalive is not a second answer, so no second record.
    let beat = h
        .app
        .clone()
        .oneshot(request(
            "POST",
            &format!("/channels/{channel_id}/voice/heartbeat"),
            Some(&bob_token),
        ))
        .await
        .unwrap();
    assert_eq!(beat.status(), StatusCode::NO_CONTENT);
    assert_eq!(calls_in(&h.app, &channel_id, &bob_token).await.len(), 1);
}

/// The caller hanging up before anyone answers goes through the leave route,
/// which cancels their own outstanding ring. From the other side that is a
/// missed call too, so it has to be recorded like one.
#[tokio::test]
async fn a_caller_hanging_up_first_records_a_canceled_call() {
    let h = harness().await;
    let (alice_token, alice_id) = register(&h.store, "alice").await;
    let (bob_token, bob_id) = register(&h.store, "bob").await;
    let channel_id = open_dm(&h.app, &alice_token, &bob_id).await;

    assert_eq!(
        ring(&h.app, &channel_id, &alice_token).await,
        StatusCode::OK
    );
    let left = h
        .app
        .clone()
        .oneshot(request(
            "DELETE",
            &format!("/channels/{channel_id}/voice/heartbeat"),
            Some(&alice_token),
        ))
        .await
        .unwrap();
    assert_eq!(left.status(), StatusCode::NO_CONTENT);

    let calls = calls_in(&h.app, &channel_id, &bob_token).await;
    assert_eq!(
        calls.len(),
        1,
        "the cancelled ring must be in bob's transcript"
    );
    assert_eq!(calls[0]["call"]["outcome"], "canceled");
    assert_eq!(calls[0]["call"]["caller_id"], alice_id);
    assert!(calls[0]["call"]["duration_ms"].is_null());
}
