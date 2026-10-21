// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The `active` frame: a client that reports real use stops having its keepalive pings count as activity, so a sleeping machine that keeps pinging goes away.

use std::time::{Duration, Instant};

use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::presence;
use slimm_server::store::Store;
use tokio::net::TcpListener;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message as WsMessage;

mod support;

type Client =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

async fn user_ticket(store: &Store, name: &str) -> (String, slimm_server::ids::UserId) {
    let user = store.create_user(name, name).await.unwrap();
    let tokens = store.open_session(user.id, "device").await.unwrap();
    let ctx = store
        .authenticate(&tokens.access_token)
        .await
        .unwrap()
        .unwrap();
    let (ticket, _expires_at) = store.mint_ws_ticket(&ctx).await.unwrap();
    (ticket, user.id)
}

async fn serve(state: AppState) -> std::net::SocketAddr {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(listener, http::router(state)).await.unwrap();
    });
    addr
}

async fn read_frame(ws: &mut Client) -> Value {
    loop {
        match ws.next().await {
            Some(Ok(WsMessage::Text(text))) => {
                return serde_json::from_str(text.as_str()).unwrap();
            }
            Some(Ok(_)) => continue,
            other => panic!("expected a text frame, got {other:?}"),
        }
    }
}

async fn send(ws: &mut Client, frame: Value) {
    ws.send(WsMessage::Text(frame.to_string())).await.unwrap();
}

/// A pong proves the server has processed every frame sent before the ping.
async fn ping_and_wait_for_pong(ws: &mut Client) {
    send(ws, json!({ "type": "ping" })).await;
    let outcome = tokio::time::timeout(Duration::from_secs(2), async {
        loop {
            if read_frame(ws).await["type"] == "pong" {
                return;
            }
        }
    })
    .await;
    assert!(outcome.is_ok(), "no pong within two seconds");
}

async fn connected(name: &str) -> (Hub, Client, slimm_server::ids::UserId, support::TestDbGuard) {
    connected_saying(name, None).await
}

async fn connected_saying(
    name: &str,
    active: Option<bool>,
) -> (Hub, Client, slimm_server::ids::UserId, support::TestDbGuard) {
    let (store, guard) = support::new_store("slimm-presence-active").await;
    let hub = Hub::new();
    let state = support::app::builder(store.clone())
        .hub(hub.clone())
        .build();
    let (ticket, id) = user_ticket(&store, name).await;
    let addr = serve(state).await;
    let (mut ws, _response) = connect_async(format!("ws://{addr}/ws")).await.unwrap();
    send(
        &mut ws,
        match active {
            Some(active) => {
                json!({ "type": "hello", "ticket": ticket, "protocol": 1, "active": active })
            }
            None => json!({ "type": "hello", "ticket": ticket, "protocol": 1 }),
        },
    )
    .await;
    assert_eq!(read_frame(&mut ws).await["type"], "hello");
    (hub, ws, id, guard)
}

fn long_ago() -> Instant {
    Instant::now() - presence::IDLE_TIMEOUT - Duration::from_secs(1)
}

#[tokio::test]
async fn an_active_frame_resets_the_idle_clock() {
    let (hub, mut ws, id, _guard) = connected("alice").await;
    hub.presence().touch_at(id, long_ago());
    assert!(hub.presence().is_idle(id));

    send(&mut ws, json!({ "type": "active" })).await;
    ping_and_wait_for_pong(&mut ws).await;

    assert!(
        !hub.presence().is_idle(id),
        "an active frame must reset the idle clock"
    );
}

#[tokio::test]
async fn after_an_active_frame_pings_no_longer_keep_the_user_online() {
    let (hub, mut ws, id, _guard) = connected("alice").await;
    send(&mut ws, json!({ "type": "active" })).await;
    ping_and_wait_for_pong(&mut ws).await;

    hub.presence().touch_at(id, long_ago());
    ping_and_wait_for_pong(&mut ws).await;

    assert!(
        hub.presence().is_idle(id),
        "a client that reports activity must go idle while only its keepalive pings arrive"
    );
}

#[tokio::test]
async fn a_client_that_never_sends_active_keeps_ping_based_presence() {
    let (hub, mut ws, id, _guard) = connected("bot").await;
    hub.presence().touch_at(id, long_ago());
    ping_and_wait_for_pong(&mut ws).await;

    assert!(
        !hub.presence().is_idle(id),
        "older clients and bots send no active frame, so their pings still count"
    );
}

#[tokio::test]
async fn a_client_that_connects_saying_nobody_is_there_starts_away() {
    let (hub, mut ws, id, _guard) = connected_saying("alice", Some(false)).await;
    ping_and_wait_for_pong(&mut ws).await;

    assert!(
        hub.presence().is_idle(id),
        "a reconnect after sleep is not use: the user must read away until an active frame"
    );

    send(&mut ws, json!({ "type": "active" })).await;
    ping_and_wait_for_pong(&mut ws).await;
    assert!(!hub.presence().is_idle(id));
}

#[tokio::test]
async fn a_client_that_connects_saying_someone_is_there_reads_online_but_pings_do_not_count() {
    let (hub, mut ws, id, _guard) = connected_saying("alice", Some(true)).await;
    ping_and_wait_for_pong(&mut ws).await;
    assert!(!hub.presence().is_idle(id));

    hub.presence().touch_at(id, long_ago());
    ping_and_wait_for_pong(&mut ws).await;
    assert!(
        hub.presence().is_idle(id),
        "declaring activity reporting in the hello turns pings off from the start"
    );
}
