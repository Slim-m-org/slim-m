// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The per-connection permission cache must never outlive the answer.
//!
//! `http/ws/permission_cache.rs` stops `authorize` re-deriving the same permission
//! five queries at a time for every message in a busy channel. The whole risk
//! it introduces points one way: a stale `true` keeps delivering a channel to
//! somebody whose view was just revoked, which is the leak the socket exists
//! to prevent, while a stale `false` only withholds something a reconnect
//! returns.
//!
//! So these drive a real socket rather than the cache struct: what matters is
//! that a revocation lands *before* the next message is authorized, and the
//! ordering between `observe` and `authorize` in the connection loop is the
//! only thing making that true. A unit test on the struct cannot see that
//! ordering, and the ordering is the part that is easy to get wrong.

use std::time::Duration;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use slimm_server::http::{self, AppState};
use slimm_server::ids::UserId;
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use tokio::net::TcpListener;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message as WsMessage;
use tower::ServiceExt;
use uuid::Uuid;

mod support;

type Client =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

async fn user_ticket(store: &Store, name: &str) -> (String, String, UserId) {
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

/// Skips `presence.changed`, which every connect on this shared hub publishes
/// and nothing here asserts on. Bounded so a missing frame panics rather than
/// hanging the runner.
async fn read_frame(ws: &mut Client) -> Value {
    tokio::time::timeout(Duration::from_secs(2), async {
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
    })
    .await
    .expect("timed out waiting for a frame")
}

/// Every frame that arrives within a short grace window.
///
/// The assertion this file needs most is a *negative* one, and a negative
/// cannot be proved by reading one frame: a leak would arrive as a second
/// frame behind an expected first. So this drains rather than peeking, and a
/// test asserts on the whole set.
async fn drain(ws: &mut Client) -> Vec<Value> {
    let mut frames = Vec::new();
    let _ = tokio::time::timeout(Duration::from_millis(600), async {
        while let Some(Ok(WsMessage::Text(text))) = ws.next().await {
            let frame: Value = serde_json::from_str(text.as_str()).unwrap();
            if frame["type"] != "presence.changed" {
                frames.push(frame);
            }
        }
    })
    .await;
    frames
}

fn req(method: &str, uri: &str, token: &str, body: Option<Value>) -> Request<Body> {
    let mut builder = Request::builder()
        .method(method)
        .uri(uri)
        .header("authorization", format!("Bearer {token}"));
    match body {
        Some(value) => {
            builder = builder.header("content-type", "application/json");
            builder.body(Body::from(value.to_string())).unwrap()
        }
        None => builder.body(Body::empty()).unwrap(),
    }
}

async fn make_admin(store: &Store, user_id: UserId) {
    let role = store
        .create_role("admin", Permissions::ADMINISTRATOR, false)
        .await
        .unwrap();
    store.assign_role(user_id, role).await.unwrap();
}

async fn send_message(state: &AppState, token: &str, channel_id: &str, body: &str) {
    let response = http::router(state.clone())
        .oneshot(req(
            "POST",
            &format!("/channels/{channel_id}/messages"),
            token,
            Some(json!({ "id": Uuid::now_v7().to_string(), "content": body })),
        ))
        .await
        .unwrap();
    assert!(
        response.status().is_success(),
        "send failed: {:?}",
        response.status()
    );
}

/// The one that matters: a member overwrite denying VIEW_CHANNEL has to stop
/// the *next* message, not the one after the cache happens to expire.
///
/// Without the epoch moving inside `publish`, bob's warm
/// `true` survives the revocation for the whole TTL and the second message
/// reaches somebody who can no longer read the channel over REST.
#[tokio::test]
async fn a_revoked_view_stops_the_very_next_message() {
    let (store, _guard) = support::new_store("slimm-ws-view-cache-test").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let state = support::app::state(store.clone());

    let (alice_access, _alice_ticket, alice) = user_ticket(&store, "alice").await;
    let (_bob_access, bob_ticket, bob) = user_ticket(&store, "bob").await;
    make_admin(&store, alice).await;

    let channel = store.create_channel("general", "text").await.unwrap();
    let channel_id = channel.id.to_string();

    let addr = serve(state.clone()).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    // Warms bob's cache with `true` for this channel.
    send_message(&state, &alice_access, &channel_id, "before").await;
    let first = read_frame(&mut bob_ws).await;
    assert_eq!(first["type"], "message.created");
    assert_eq!(first["message"]["content"], "before");

    let response = http::router(state.clone())
        .oneshot(req(
            "PUT",
            &format!("/channels/{channel_id}/overwrites/member/{bob}"),
            &alice_access,
            Some(json!({ "allow": 0, "deny": Permissions::VIEW_CHANNEL.bits() })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    send_message(&state, &alice_access, &channel_id, "after").await;

    let frames = drain(&mut bob_ws).await;
    let bodies: Vec<&str> = frames
        .iter()
        .filter(|f| f["type"] == "message.created")
        .map(|f| f["message"]["content"].as_str().unwrap_or_default())
        .collect();
    assert!(
        bodies.is_empty(),
        "bob's VIEW_CHANNEL was revoked and he still received {bodies:?}",
    );
    // The revocation itself still reaches him; that is `held_it_before`.
    assert!(
        frames.iter().any(|f| f["type"] == "overwrite.changed"),
        "bob should still be told his own view was revoked, got {frames:?}",
    );
}

/// The other direction, which a cache that simply never invalidated would
/// also pass: granting a view has to take effect on the next message too.
#[tokio::test]
async fn a_granted_view_starts_delivering_at_once() {
    let (store, _guard) = support::new_store("slimm-ws-view-cache-test").await;
    // No VIEW_CHANNEL: bob starts unable to see anything.
    store
        .create_role("everyone", Permissions::SEND_MESSAGES, true)
        .await
        .unwrap();
    let state = support::app::state(store.clone());

    let (alice_access, _alice_ticket, alice) = user_ticket(&store, "alice").await;
    let (_bob_access, bob_ticket, bob) = user_ticket(&store, "bob").await;
    make_admin(&store, alice).await;

    let channel = store.create_channel("general", "text").await.unwrap();
    let channel_id = channel.id.to_string();

    let addr = serve(state.clone()).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    // Warms bob's cache with `false`.
    send_message(&state, &alice_access, &channel_id, "unseen").await;
    let early = drain(&mut bob_ws).await;
    assert!(
        !early.iter().any(|f| f["type"] == "message.created"),
        "bob cannot view this channel yet, got {early:?}",
    );

    let response = http::router(state.clone())
        .oneshot(req(
            "PUT",
            &format!("/channels/{channel_id}/overwrites/member/{bob}"),
            &alice_access,
            Some(json!({ "allow": Permissions::VIEW_CHANNEL.bits(), "deny": 0 })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    send_message(&state, &alice_access, &channel_id, "seen").await;

    let frames = drain(&mut bob_ws).await;
    assert!(
        frames
            .iter()
            .any(|f| f["type"] == "message.created" && f["message"]["content"] == "seen"),
        "bob was granted the view and did not receive the next message: {frames:?}",
    );
}

/// A role edit moves permissions for everyone holding it, and the event names
/// only the role, so a connection cannot tell whether it is affected. Losing
/// the view this way has to stop delivery just as an overwrite does.
#[tokio::test]
async fn a_role_edit_that_removes_the_view_stops_delivery() {
    let (store, _guard) = support::new_store("slimm-ws-view-cache-test").await;
    let everyone = store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let state = support::app::state(store.clone());

    let (alice_access, _alice_ticket, alice) = user_ticket(&store, "alice").await;
    let (_bob_access, bob_ticket, _bob) = user_ticket(&store, "bob").await;
    make_admin(&store, alice).await;

    let channel = store.create_channel("general", "text").await.unwrap();
    let channel_id = channel.id.to_string();

    let addr = serve(state.clone()).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    send_message(&state, &alice_access, &channel_id, "before").await;
    let first = read_frame(&mut bob_ws).await;
    assert_eq!(first["message"]["content"], "before");

    let response = http::router(state.clone())
        .oneshot(req(
            "PATCH",
            &format!("/roles/{everyone}"),
            &alice_access,
            Some(json!({ "permissions": Permissions::SEND_MESSAGES.bits() })),
        ))
        .await
        .unwrap();
    assert!(
        response.status().is_success(),
        "role patch: {:?}",
        response.status()
    );

    send_message(&state, &alice_access, &channel_id, "after").await;

    let frames = drain(&mut bob_ws).await;
    let bodies: Vec<&str> = frames
        .iter()
        .filter(|f| f["type"] == "message.created")
        .map(|f| f["message"]["content"].as_str().unwrap_or_default())
        .collect();
    assert!(
        bodies.is_empty(),
        "@everyone lost VIEW_CHANNEL and bob still received {bodies:?}",
    );
}
