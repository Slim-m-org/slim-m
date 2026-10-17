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
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::http::{self, AppState};
use slimm_server::hub::{Hub, MemoryReading};
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::Store;
use tokio::net::TcpListener;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::{Error as WsError, Message as WsMessage};

mod support;

type Client =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

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
    AppState {
        store: store.clone(),
        auth: Auth::new(2).unwrap(),
        hub,
        limiter: RateLimiter::new(),
        push: PushSender::disabled(),
        voice: slimm_server::voice::VoiceService::disabled(),
        media: slimm_server::media::Media::for_tests(),
        gifs: slimm_server::http::gifs::GifSearch::disabled(),
        link_previews: slimm_server::http::link_preview::LinkPreviews::disabled(),
        dock: slimm_server::http::dock::Dock::disabled(),
        code_runner: slimm_server::code_runner::CodeRunner::disabled(),
    }
}

async fn serve(state: AppState) -> std::net::SocketAddr {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(listener, http::router(state)).await.unwrap();
    });
    addr
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

async fn connect(addr: std::net::SocketAddr, ticket: &str) -> Client {
    let (mut ws, _response) = connect_async(format!("ws://{addr}/ws")).await.unwrap();
    ws.send(WsMessage::Text(
        json!({ "type": "hello", "ticket": ticket, "protocol": 1 }).to_string(),
    ))
    .await
    .unwrap();
    let ack = read_frame(&mut ws).await;
    assert_eq!(ack["type"], "hello");
    ws
}

/// Reads the next text frame as JSON, skipping `presence.changed` - this
/// connection's own connect can publish one on the shared hub before the
/// caller starts reading, and it is expected chatter rather than something
/// this test checks (see `tests/ws.rs`'s identical helper).
async fn read_frame(ws: &mut Client) -> Value {
    loop {
        match ws.next().await {
            Some(Ok(WsMessage::Text(text))) => {
                let frame: Value = serde_json::from_str(text.as_str()).unwrap();
                if frame["type"] == "presence.changed" {
                    continue;
                }
                return frame;
            }
            Some(Ok(_)) => continue,
            other => panic!("expected a text frame, got {other:?}"),
        }
    }
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
    let pong = read_frame(&mut alice).await;
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
    let pong = read_frame(&mut ws).await;
    assert_eq!(pong["type"], "pong");
}
