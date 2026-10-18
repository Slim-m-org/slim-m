// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A session that reconnects after losing its socket is online again to
//! everyone, through both the WebSocket broadcast and the REST lookup.

use std::time::Duration;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::store::Store;
use tokio::net::TcpListener;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message as WsMessage;
use tower::ServiceExt;

mod support;

type Client =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

/// Creates a user and returns (rest access token, ws connect ticket, user id).
async fn user_ticket(store: &Store, name: &str) -> (String, String, slimm_server::ids::UserId) {
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

async fn serve(state: AppState) -> std::net::SocketAddr {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(listener, http::router(state)).await.unwrap();
    });
    addr
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

/// Reads frames until one is a `presence.changed` for `user_id`, ignoring any
/// other event kind. Bounded so a missing event fails the test instead of
/// hanging it.
async fn next_presence_for(ws: &mut Client, user_id: &str) -> Value {
    let outcome = tokio::time::timeout(Duration::from_secs(2), async {
        loop {
            let frame = read_frame(ws).await;
            if frame["type"] == "presence.changed" && frame["user_id"] == user_id {
                return frame;
            }
        }
    })
    .await;
    outcome.unwrap_or_else(|_| panic!("no presence.changed for {user_id} arrived in time"))
}

fn get_request(uri: &str, token: &str) -> Request<Body> {
    Request::builder()
        .method("GET")
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap()
}

async fn presence_status(state: &AppState, token: &str, target_id: &str) -> String {
    let uri = format!("/presence?ids={target_id}");
    let response = http::router(state.clone())
        .oneshot(get_request(&uri, token))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let body = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    let entries: Vec<Value> = serde_json::from_slice(&body).unwrap();
    entries[0]["status"].as_str().unwrap().to_owned()
}

/// The server holds no presence past a socket's life, so a client that lost
/// its socket and reconnects reads online again with nothing re-announced. A
/// client that never notices the loss stays offline to everyone instead.
#[tokio::test]
async fn a_reconnecting_session_is_online_again_without_re_announcing() {
    let (store, _guard) = support::new_store("slimm-presence-test").await;
    let state = support::app::builder(store.clone()).hub(Hub::new()).build();
    let (alice_access, alice_ticket, alice_id) = user_ticket(&store, "alice").await;
    let (bob_access, bob_ticket, bob_id) = user_ticket(&store, "bob").await;
    let alice_id_str = alice_id.to_string();

    let addr = serve(state.clone()).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;
    let _ = next_presence_for(&mut bob_ws, &bob_id.to_string()).await;

    let alice_ws = connect(addr, &alice_ticket).await;
    assert_eq!(
        next_presence_for(&mut bob_ws, &alice_id_str).await["status"],
        "online"
    );
    drop(alice_ws);
    assert_eq!(
        next_presence_for(&mut bob_ws, &alice_id_str).await["status"],
        "offline"
    );

    let ctx = store.authenticate(&alice_access).await.unwrap().unwrap();
    let (fresh_ticket, _expires_at) = store.mint_ws_ticket(&ctx).await.unwrap();
    let _alice_again = connect(addr, &fresh_ticket).await;
    assert_eq!(
        next_presence_for(&mut bob_ws, &alice_id_str).await["status"],
        "online"
    );
    assert_eq!(
        presence_status(&state, &bob_access, &alice_id_str).await,
        "online"
    );
}
