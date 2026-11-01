// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What the socket does with a connection that has not yet proven who it is:
//! bad hellos, expired tickets, the pre-auth deadline and the per-address cap.

use std::net::SocketAddr;
use std::time::Duration;

use futures_util::SinkExt;
use serde_json::json;
use slimm_server::hub::Hub;
use slimm_server::ratelimit::RateLimiter;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message as WsMessage;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;

mod support;

use support::ws::{Client, read_frame, serve, ticket_only};

const DEADLINE: Duration = Duration::from_secs(10);

async fn connect_from(addr: SocketAddr, forwarded: &str) -> Result<Client, String> {
    let mut request = format!("ws://{addr}/ws").into_client_request().unwrap();
    request
        .headers_mut()
        .insert("x-forwarded-for", forwarded.parse().unwrap());
    connect_async(request)
        .await
        .map(|(ws, _)| ws)
        .map_err(|e| e.to_string())
}

async fn serve_with(
    prefix: &str,
    hub: Hub,
) -> (
    SocketAddr,
    slimm_server::store::Store,
    sqlx::SqlitePool,
    support::TestDbGuard,
) {
    let (store, pool, guard) = support::new_store_with_pool(prefix).await;
    let state = support::app::builder(store.clone())
        .hub(hub)
        .limiter(RateLimiter::with_trusted_hops(1))
        .build();
    (serve(state).await, store, pool, guard)
}

async fn hello(ws: &mut Client, ticket: &str, protocol: u32) {
    ws.send(WsMessage::Text(
        json!({ "type": "hello", "ticket": ticket, "protocol": protocol }).to_string(),
    ))
    .await
    .unwrap();
}

async fn assert_error_frame(ws: &mut Client, message: &str) {
    let frame = tokio::time::timeout(DEADLINE, read_frame(ws))
        .await
        .unwrap();
    assert_eq!(frame["type"], "error");
    assert_eq!(frame["message"], message);
}

#[tokio::test]
async fn an_expired_ticket_is_refused() {
    let (addr, store, pool, _guard) = serve_with("slimm-ws-hs", Hub::new()).await;
    let ticket = ticket_only(&store, "alice").await;
    sqlx::query("UPDATE ws_tickets SET expires_at = 1")
        .execute(&pool)
        .await
        .unwrap();

    let mut ws = connect_from(addr, "1.1.1.1").await.unwrap();
    hello(&mut ws, &ticket, 1).await;
    assert_error_frame(&mut ws, "invalid ticket").await;
}

#[tokio::test]
async fn a_wrong_protocol_version_is_refused() {
    let (addr, store, _pool, _guard) = serve_with("slimm-ws-hs", Hub::new()).await;
    let ticket = ticket_only(&store, "alice").await;

    let mut ws = connect_from(addr, "1.1.1.1").await.unwrap();
    hello(&mut ws, &ticket, 999).await;
    assert_error_frame(&mut ws, "unsupported protocol version").await;
}

#[tokio::test]
async fn a_first_frame_that_is_not_a_hello_is_refused() {
    let (addr, _store, _pool, _guard) = serve_with("slimm-ws-hs", Hub::new()).await;

    let mut ws = connect_from(addr, "1.1.1.1").await.unwrap();
    ws.send(WsMessage::Text(json!({ "type": "ping" }).to_string()))
        .await
        .unwrap();
    assert_error_frame(&mut ws, "expected a hello frame").await;

    let mut ws = connect_from(addr, "1.1.1.2").await.unwrap();
    ws.send(WsMessage::Binary(vec![1, 2, 3])).await.unwrap();
    assert_error_frame(&mut ws, "expected a hello frame").await;
}

#[tokio::test]
async fn a_silent_socket_is_dropped_at_the_auth_deadline() {
    let hub = Hub::with_handshake_limits(8, Duration::from_millis(200));
    let (addr, _store, _pool, _guard) = serve_with("slimm-ws-hs", hub).await;

    let mut ws = connect_from(addr, "1.1.1.1").await.unwrap();
    assert_error_frame(&mut ws, "expected a hello frame").await;
}

#[tokio::test]
async fn one_address_cannot_hold_more_than_its_share_of_pending_sockets() {
    let hub = Hub::with_handshake_limits(2, DEADLINE);
    let (addr, store, _pool, _guard) = serve_with("slimm-ws-hs", hub).await;

    let mut first = connect_from(addr, "1.1.1.1").await.unwrap();
    let _second = connect_from(addr, "1.1.1.1").await.unwrap();
    let refused = connect_from(addr, "1.1.1.1").await;
    assert!(refused.is_err(), "a third pending socket got in");
    connect_from(addr, "2.2.2.2")
        .await
        .expect("another address is unaffected");

    // Authenticating frees the claim.
    let ticket = ticket_only(&store, "alice").await;
    hello(&mut first, &ticket, 1).await;
    assert_eq!(read_frame(&mut first).await["type"], "hello");
    connect_from(addr, "1.1.1.1")
        .await
        .expect("a freed slot is usable again");
}

#[tokio::test]
async fn the_connection_ceiling_refuses_with_503_and_frees_on_close() {
    let hub = Hub::with_connection_limit(1);
    let (addr, store, _pool, _guard) = serve_with("slimm-ws-hs", hub).await;
    let ticket = ticket_only(&store, "alice").await;

    let mut first = connect_from(addr, "1.1.1.1").await.unwrap();
    hello(&mut first, &ticket, 1).await;
    assert_eq!(read_frame(&mut first).await["type"], "hello");

    let refused = connect_from(addr, "2.2.2.2").await.unwrap_err();
    assert!(refused.contains("503"), "expected a 503, got {refused}");

    first.close(None).await.unwrap();
    drop(first);
    let deadline = tokio::time::Instant::now() + DEADLINE;
    loop {
        match connect_from(addr, "2.2.2.2").await {
            Ok(_) => break,
            Err(_) if tokio::time::Instant::now() < deadline => {
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
            Err(err) => panic!("the slot never came back: {err}"),
        }
    }
}

#[tokio::test]
async fn a_frame_over_the_4_kib_cap_closes_an_authenticated_socket() {
    let (addr, store, _pool, _guard) = serve_with("slimm-ws-hs", Hub::new()).await;
    let ticket = ticket_only(&store, "alice").await;
    let mut ws = connect_from(addr, "1.1.1.1").await.unwrap();
    hello(&mut ws, &ticket, 1).await;
    assert_eq!(read_frame(&mut ws).await["type"], "hello");

    let oversized = json!({ "type": "ping", "padding": "x".repeat(5 * 1024) });
    // The server may reset the connection before the send finishes; either way it must end.
    let _ = ws.send(WsMessage::Text(oversized.to_string())).await;

    let ended = tokio::time::timeout(DEADLINE, async {
        while let Some(Ok(_)) = futures_util::StreamExt::next(&mut ws).await {}
    })
    .await;
    assert!(
        ended.is_ok(),
        "the socket stayed open after an oversized frame"
    );
}
