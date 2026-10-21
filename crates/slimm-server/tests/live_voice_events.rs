// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Live coverage for `Event::VoiceActivityChanged`: the in-app half of "a DM
//! call reaches nobody" (`docs/IMPLIED-GAPS.md` #2). Before this, joining or
//! leaving a voice call published nothing over the socket at all, so a DM
//! contact with the app open had no way to learn a call had started short of
//! polling the roster on their own initiative.
//!
//! The permission gate is not new logic - `VoiceActivityChanged` is folded
//! into the same channel-scoped check every other channel event already uses
//! in `http::ws::authorize` - so what needs proof here is that the event
//! actually reaches a DM's other participant and nobody else, and that it
//! carries no participant identity at all (see the event's own doc comment
//! for why: `GET .../voice/roster` is per-viewer filtered for appear-offline,
//! and naming a joiner here would be a second, unfiltered way to learn who is
//! on a call).

use std::time::Duration;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use slimm_server::http::{self, AppState};
use slimm_server::store::Store;
use slimm_server::voice::VoiceService;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message as WsMessage;
use tower::ServiceExt;

mod support;

use support::ws::{Client, serve, user_ticket};

fn enabled_voice() -> VoiceService {
    VoiceService::for_test(
        "wss://livekit.example.com",
        "APItestkey",
        "a-test-secret-of-at-least-32-characters",
    )
}

fn state_for(store: &Store) -> AppState {
    support::app::builder(store.clone())
        .voice(enabled_voice())
        .build()
}

async fn connect(addr: std::net::SocketAddr, ticket: &str) -> Client {
    let (mut ws, _response) = connect_async(format!("ws://{addr}/ws")).await.unwrap();
    ws.send(WsMessage::Text(
        json!({ "type": "hello", "ticket": ticket, "protocol": 1 }).to_string(),
    ))
    .await
    .unwrap();
    let ack = wait_for(&mut ws, "hello", Duration::from_secs(2))
        .await
        .expect("hello ack");
    assert_eq!(ack["type"], "hello");
    ws
}

/// Waits up to `timeout` for a frame whose `type` is `kind`, discarding
/// anything else - `None` on timeout, never a panic, so this doubles as both
/// the positive and the negative half of a delivery assertion.
async fn wait_for(ws: &mut Client, kind: &str, timeout: Duration) -> Option<Value> {
    tokio::time::timeout(timeout, async {
        loop {
            match ws.next().await {
                Some(Ok(WsMessage::Text(text))) => {
                    let frame: Value = serde_json::from_str(text.as_str()).unwrap();
                    if frame["type"] == kind {
                        return frame;
                    }
                }
                Some(Ok(_)) => continue,
                other => panic!("expected a text frame, got {other:?}"),
            }
        }
    })
    .await
    .ok()
}

async fn read_frame_of_type(ws: &mut Client, kind: &str) -> Value {
    wait_for(ws, kind, Duration::from_secs(2))
        .await
        .unwrap_or_else(|| panic!("timed out waiting for a `{kind}` frame"))
}

fn req(method: &str, uri: &str, token: &str) -> Request<Body> {
    Request::builder()
        .method(method)
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap()
}

/// The bug the task exists to close: a caller who starts a DM call gets
/// silence, with no indication the other side even knows. A stranger who is
/// not a party to the DM is the control - denied `VIEW_CHANNEL`, they must
/// learn nothing either, the same shape `live_thread_events.rs` uses for
/// carol.
#[tokio::test]
async fn a_dm_call_starting_reaches_the_other_participant_but_not_a_stranger() {
    let (store, _guard) = support::new_store("slimm-live-voice-events-test").await;
    let (alice_access, _alice_ticket, alice_id) = user_ticket(&store, "alice").await;
    let (_bob_access, bob_ticket, bob_id) = user_ticket(&store, "bob").await;
    let (_eve_access, eve_ticket, _eve_id) = user_ticket(&store, "eve").await;
    let channel = store.open_dm(alice_id, bob_id).await.unwrap();
    let state = state_for(&store);

    let addr = serve(state.clone()).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;
    let mut eve_ws = connect(addr, &eve_ticket).await;

    let heartbeat_uri = format!("/channels/{}/voice/heartbeat", channel.id);
    let response = http::router(state.clone())
        .oneshot(req("POST", &heartbeat_uri, &alice_access))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    let frame = read_frame_of_type(&mut bob_ws, "voice.activity").await;
    assert_eq!(frame["channel_id"], channel.id.to_string());
    assert_eq!(
        frame.as_object().unwrap().len(),
        2,
        "the frame must carry only `type` and `channel_id`, never who joined: {frame}"
    );

    assert!(
        wait_for(&mut eve_ws, "voice.activity", Duration::from_millis(300))
            .await
            .is_none(),
        "eve is not a party to this DM and must not learn a call started in it"
    );
}

/// A heartbeat is sent on a plain interval for as long as a call lasts; only
/// the first one for a `(user, channel)` pair is news.
#[tokio::test]
async fn a_repeated_heartbeat_does_not_republish() {
    let (store, _guard) = support::new_store("slimm-live-voice-events-test").await;
    let (alice_access, _alice_ticket, alice_id) = user_ticket(&store, "alice").await;
    let (_bob_access, bob_ticket, bob_id) = user_ticket(&store, "bob").await;
    let channel = store.open_dm(alice_id, bob_id).await.unwrap();
    let state = state_for(&store);

    let addr = serve(state.clone()).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    let heartbeat_uri = format!("/channels/{}/voice/heartbeat", channel.id);
    for _ in 0..3 {
        let response = http::router(state.clone())
            .oneshot(req("POST", &heartbeat_uri, &alice_access))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::NO_CONTENT);
    }

    read_frame_of_type(&mut bob_ws, "voice.activity").await;
    assert!(
        wait_for(&mut bob_ws, "voice.activity", Duration::from_millis(300))
            .await
            .is_none(),
        "the second and third heartbeat for the same call must not republish"
    );
}

/// A clean hangup (`DELETE .../voice/heartbeat`) is the second of the three
/// publish sites, alongside the first heartbeat above and the stale-sweep
/// eviction covered in `voice_sweep.rs`.
#[tokio::test]
async fn a_clean_hangup_publishes_too() {
    let (store, _guard) = support::new_store("slimm-live-voice-events-test").await;
    let (alice_access, _alice_ticket, alice_id) = user_ticket(&store, "alice").await;
    let (_bob_access, bob_ticket, bob_id) = user_ticket(&store, "bob").await;
    let channel = store.open_dm(alice_id, bob_id).await.unwrap();
    let state = state_for(&store);

    let addr = serve(state.clone()).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    let heartbeat_uri = format!("/channels/{}/voice/heartbeat", channel.id);
    http::router(state.clone())
        .oneshot(req("POST", &heartbeat_uri, &alice_access))
        .await
        .unwrap();
    read_frame_of_type(&mut bob_ws, "voice.activity").await;

    let response = http::router(state.clone())
        .oneshot(req("DELETE", &heartbeat_uri, &alice_access))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    read_frame_of_type(&mut bob_ws, "voice.activity").await;
}

/// Forgetting a heartbeat that was never recorded (a stray or repeated
/// `DELETE`) must not fan out a signal for a call that never changed.
#[tokio::test]
async fn forgetting_a_heartbeat_never_recorded_publishes_nothing() {
    let (store, _guard) = support::new_store("slimm-live-voice-events-test").await;
    let (alice_access, _alice_ticket, alice_id) = user_ticket(&store, "alice").await;
    let (_bob_access, bob_ticket, bob_id) = user_ticket(&store, "bob").await;
    let channel = store.open_dm(alice_id, bob_id).await.unwrap();
    let state = state_for(&store);

    let addr = serve(state.clone()).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    let heartbeat_uri = format!("/channels/{}/voice/heartbeat", channel.id);
    let response = http::router(state.clone())
        .oneshot(req("DELETE", &heartbeat_uri, &alice_access))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    assert!(
        wait_for(&mut bob_ws, "voice.activity", Duration::from_millis(300))
            .await
            .is_none()
    );
}
