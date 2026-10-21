// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The memory-admission guard end to end: an already-open WebSocket
//! connection is untouched while the guard is refusing new ones, and a
//! refused client can tell why from the 503 body - the same shape the
//! connection-count cap already answers with. See `hub::memory_guard`'s own
//! doc comment for the guard itself; its decision logic and cgroup parsing
//! are unit-tested there directly against injected readings, never the real
//! filesystem.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use axum::http::StatusCode;
use futures_util::SinkExt;
use serde_json::json;
use slimm_server::http::AppState;
use slimm_server::hub::{Hub, MemoryReading};
use slimm_server::store::Store;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::{Error as WsError, Message as WsMessage};

mod support;

use support::ws::{connect, read_frame_skipping_presence, serve};

/// Comfortably above the guard's 64 MiB reserve (see `hub::memory_guard`).
fn healthy() -> MemoryReading {
    MemoryReading {
        limit_bytes: Some(1_000_000_000),
        usage_bytes: Some(100_000_000),
    }
}

/// Well under a megabyte of headroom - comfortably below the reserve.
fn starved() -> MemoryReading {
    MemoryReading {
        limit_bytes: Some(1_000_000_000),
        usage_bytes: Some(999_500_000),
    }
}

fn state_with(store: &Store, hub: Hub) -> AppState {
    support::app::builder(store.clone()).hub(hub).build()
}

async fn ticket_for(store: &Store, name: &str) -> String {
    let user = store.create_user(name, name).await.unwrap();
    let tokens = store.open_session(user.id, "device").await.unwrap();
    let ctx = store
        .authenticate(&tokens.access_token)
        .await
        .unwrap()
        .unwrap();
    let (ticket, _expires_at) = store.mint_ws_ticket(&ctx).await.unwrap();
    ticket
}

#[tokio::test]
async fn an_existing_connection_survives_the_guard_refusing_new_ones() {
    let (store, _guard) = support::new_store("slimm-memguard-test").await;
    let shared = Arc::new(Mutex::new(healthy()));
    let hub = Hub::with_memory_reading(shared.clone());
    let addr = serve(state_with(&store, hub)).await;

    let alice_ticket = ticket_for(&store, "alice").await;
    let mut alice = connect(addr, &alice_ticket).await;

    // Outlasts the guard's cache window (hub::memory_guard) so the next admission check reads this.
    *shared.lock().unwrap() = starved();
    tokio::time::sleep(Duration::from_millis(400)).await;

    match connect_async(format!("ws://{addr}/ws")).await {
        Err(WsError::Http(response)) => {
            assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
            let body = response.body().clone().unwrap_or_default();
            assert_eq!(
                String::from_utf8(body).unwrap(),
                "insufficient memory headroom",
                "the refusal must say why, distinctly from the connection-count cap"
            );
        }
        other => panic!("expected the handshake to be rejected with a 503, got {other:?}"),
    }

    // Alice's connection, opened before the guard started refusing, still round-trips a ping.
    alice
        .send(WsMessage::Text(json!({ "type": "ping" }).to_string()))
        .await
        .unwrap();
    let pong = read_frame_skipping_presence(&mut alice).await;
    assert_eq!(pong["type"], "pong");
}

#[tokio::test]
async fn a_healthy_reading_admits_normally() {
    let (store, _guard) = support::new_store("slimm-memguard-test").await;
    let hub = Hub::with_memory_reading(Arc::new(Mutex::new(healthy())));
    let addr = serve(state_with(&store, hub)).await;

    let ticket = ticket_for(&store, "alice").await;
    let mut ws = connect(addr, &ticket).await;
    ws.send(WsMessage::Text(json!({ "type": "ping" }).to_string()))
        .await
        .unwrap();
    let pong = read_frame_skipping_presence(&mut ws).await;
    assert_eq!(pong["type"], "pong");
}
