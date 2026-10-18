// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Live drag and resize preview relay: the same two-bit authorization, the
//! appear-offline guard, the bounds check and the rate limit a cursor gets.

use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::permissions::Permissions;
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

async fn next_of_type(ws: &mut Client, frame_type: &str) -> Value {
    let outcome = tokio::time::timeout(Duration::from_secs(2), async {
        loop {
            let frame = read_frame(ws).await;
            if frame["type"] == frame_type {
                return frame;
            }
        }
    })
    .await;
    outcome.unwrap_or_else(|_| panic!("no {frame_type} arrived in time"))
}

async fn assert_nothing_of_type(ws: &mut Client, frame_type: &str) {
    let outcome =
        tokio::time::timeout(Duration::from_millis(300), next_of_type(ws, frame_type)).await;
    assert!(outcome.is_err(), "unexpected {frame_type}");
}

async fn send_preview(ws: &mut Client, channel_id: &str, x: f64, y: f64) {
    let object_id = slimm_server::ids::CanvasObjectId::generate().to_string();
    ws.send(WsMessage::Text(
        json!({
            "type": "canvas.object_preview", "channel_id": channel_id,
            "object_id": object_id, "x": x, "y": y, "w": 40.0, "h": 20.0,
        })
        .to_string(),
    ))
    .await
    .unwrap();
}

/// The load-bearing pair: a viewer holding both bits receives the frame, and
/// a viewer denied `USE_CANVAS` specifically (below) receives nothing, even
/// though `VIEW_CHANNEL` alone would already pass a plain channel-scoped
/// check. Mirrors `canvas_live.rs`'s placement test for the same reason: a
/// cache or a gate that only remembers the view bit would deliver here.
#[tokio::test]
async fn a_viewer_with_both_bits_receives_the_preview() {
    let (store, _guard) = support::new_store("slimm-canvas-object-preview-live").await;
    let (alice_ticket, alice_id) = user_ticket(&store, "alice").await;
    store.bootstrap_deployment(alice_id).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;
    let (bob_ticket, _bob_id) = user_ticket(&store, "bob").await;

    let state = support::app::builder(store.clone()).hub(Hub::new()).build();
    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    send_preview(&mut alice_ws, &channel.to_string(), 12.5, -4.0).await;

    let frame = next_of_type(&mut bob_ws, "canvas.object_preview.updated").await;
    assert_eq!(frame["channel_id"], channel.to_string());
    assert_eq!(frame["user_id"], alice_id.to_string());
    assert_eq!(frame["x"], 12.5);
    assert_eq!(frame["y"], -4.0);
    assert_eq!(frame["w"], 40.0);
    assert_eq!(frame["ended"], false);
}

#[tokio::test]
async fn a_member_denied_use_canvas_never_sees_a_preview() {
    let (store, _guard) = support::new_store("slimm-canvas-object-preview-live").await;
    let (alice_ticket, alice_id) = user_ticket(&store, "alice").await;
    store.bootstrap_deployment(alice_id).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;

    let (carol_ticket, carol_id) = user_ticket(&store, "carol").await;
    store
        .set_member_overwrite(
            channel,
            carol_id,
            Permissions::NONE,
            Permissions::USE_CANVAS,
        )
        .await
        .unwrap();

    let state = support::app::builder(store.clone()).hub(Hub::new()).build();
    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut carol_ws = connect(addr, &carol_ticket).await;

    send_preview(&mut alice_ws, &channel.to_string(), 12.5, -4.0).await;

    assert_nothing_of_type(&mut carol_ws, "canvas.object_preview.updated").await;
}

/// A cursor also leaks presence the same way typing does, so a user who
/// chose to appear offline must not have their pointer announced.
#[tokio::test]
async fn a_hidden_users_preview_is_not_announced() {
    use slimm_server::presence::Visibility;
    let (store, _guard) = support::new_store("slimm-canvas-object-preview-live").await;
    let (alice_ticket, alice_id) = user_ticket(&store, "alice").await;
    store.bootstrap_deployment(alice_id).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;
    store
        .set_presence_visibility(alice_id, Visibility::Hidden)
        .await
        .unwrap();
    let (bob_ticket, _bob_id) = user_ticket(&store, "bob").await;

    let state = support::app::builder(store.clone()).hub(Hub::new()).build();
    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    send_preview(&mut alice_ws, &channel.to_string(), 1.0, 1.0).await;

    assert_nothing_of_type(&mut bob_ws, "canvas.object_preview.updated").await;
}

/// A position outside the bounded world (or non-finite) is dropped outright,
/// never relayed: nothing downstream clamps it, so a receiver's paint layer
/// would otherwise have to defend against a coordinate it can never trust.
#[tokio::test]
async fn an_out_of_bounds_preview_is_dropped() {
    let (store, _guard) = support::new_store("slimm-canvas-object-preview-live").await;
    let (alice_ticket, alice_id) = user_ticket(&store, "alice").await;
    store.bootstrap_deployment(alice_id).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;
    let (bob_ticket, _bob_id) = user_ticket(&store, "bob").await;

    let state = support::app::builder(store.clone()).hub(Hub::new()).build();
    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    send_preview(&mut alice_ws, &channel.to_string(), 50_000_000.0, 0.0).await;

    assert_nothing_of_type(&mut bob_ws, "canvas.object_preview.updated").await;
}

/// Cursor frames are rate limited independently of the channel: a tight loop
/// across enough distinct channels that every send would otherwise be a
/// fresh frame still caps how many actually fan out.
#[tokio::test]
async fn object_preview_frames_are_rate_limited() {
    let (store, _guard) = support::new_store("slimm-canvas-object-preview-live").await;
    let (alice_ticket, alice_id) = user_ticket(&store, "alice").await;
    store.bootstrap_deployment(alice_id).await.unwrap();
    let (bob_ticket, _bob_id) = user_ticket(&store, "bob").await;

    let state = support::app::builder(store.clone()).hub(Hub::new()).build();
    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    let mut channel_ids = Vec::new();
    for i in 0..60 {
        let channel = store
            .create_channel(&format!("canvas-object-preview-rl-{i}"), "text")
            .await
            .unwrap();
        channel_ids.push(channel.id.to_string());
    }

    for channel_id in &channel_ids {
        send_preview(&mut alice_ws, channel_id, 1.0, 1.0).await;
    }

    let mut seen = 0usize;
    loop {
        let next = tokio::time::timeout(Duration::from_millis(500), read_frame(&mut bob_ws)).await;
        match next {
            Ok(frame) if frame["type"] == "canvas.object_preview.updated" => seen += 1,
            Ok(_) => {}
            Err(_) => break,
        }
    }

    assert!(seen >= 1, "at least the burst-allowed frames get through");
    assert!(
        seen < channel_ids.len(),
        "the rate limiter must refuse some of {} rapid frames, only {seen} got through",
        channel_ids.len()
    );
}

/// A preview shows a member moving content, so a timed-out member may not
/// send one even though a cursor is allowed.
#[tokio::test]
async fn a_timed_out_member_cannot_send_a_preview() {
    let (store, _guard) = support::new_store("slimm-canvas-object-preview-live").await;
    let (alice_ticket, alice_id) = user_ticket(&store, "alice").await;
    store.bootstrap_deployment(alice_id).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;
    let (bob_ticket, bob_id) = user_ticket(&store, "bob").await;

    let until = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
        + 60_000;
    store
        .set_member_timeout(bob_id, until, Some("cool off"), alice_id)
        .await
        .unwrap();

    let state = support::app::builder(store.clone()).hub(Hub::new()).build();
    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    send_preview(&mut bob_ws, &channel.to_string(), 1.0, 1.0).await;

    assert_nothing_of_type(&mut alice_ws, "canvas.object_preview.updated").await;
}
