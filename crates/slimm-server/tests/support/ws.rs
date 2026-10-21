// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A real listener, a ticketed `/ws` connection and frame reads, shared by
//! every live-socket test binary.

use std::net::SocketAddr;
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use slimm_server::http::{self, AppState};
use slimm_server::ids::UserId;
use slimm_server::store::Store;
use tokio::net::TcpListener;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message as WsMessage;

pub type Client =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

/// Creates a user and returns (rest access token, ws connect ticket, user id).
pub async fn user_ticket(store: &Store, name: &str) -> (String, String, UserId) {
    let user = store.create_user(name, name).await.unwrap();
    let tokens = store.open_session(user.id, "device").await.unwrap();
    let ctx = store
        .authenticate(&tokens.access_token)
        .await
        .unwrap()
        .unwrap();
    let (ticket, _expires_at) = store.mint_ws_ticket(&ctx).await.unwrap();
    (tokens.access_token, ticket, user.id)
}

/// [`user_ticket`] without the REST access token.
pub async fn user_ticket_and_id(store: &Store, name: &str) -> (String, UserId) {
    let (_, ticket, id) = user_ticket(store, name).await;
    (ticket, id)
}

/// [`user_ticket`] without the user id.
pub async fn user_access_ticket(store: &Store, name: &str) -> (String, String) {
    let (access, ticket, _) = user_ticket(store, name).await;
    (access, ticket)
}

/// [`user_ticket`] keeping only the ws ticket.
pub async fn ticket_only(store: &Store, name: &str) -> String {
    user_ticket(store, name).await.1
}

pub async fn serve(state: AppState) -> SocketAddr {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(listener, http::router(state)).await.unwrap();
    });
    addr
}

/// Connects and completes the `hello` handshake.
pub async fn connect(addr: SocketAddr, ticket: &str) -> Client {
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

/// The next text frame as JSON, whatever it is.
pub async fn read_frame(ws: &mut Client) -> Value {
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

/// [`read_frame`] minus `presence.changed`, which every connect publishes.
pub async fn read_frame_skipping_presence(ws: &mut Client) -> Value {
    loop {
        let frame = read_frame(ws).await;
        if frame["type"] != "presence.changed" {
            return frame;
        }
    }
}

/// Bounded so a missing publish fails fast instead of hanging the runner.
pub async fn read_frame_skipping_presence_timed(ws: &mut Client) -> Value {
    tokio::time::timeout(Duration::from_secs(2), read_frame_skipping_presence(ws))
        .await
        .expect("timed out waiting for a frame")
}
