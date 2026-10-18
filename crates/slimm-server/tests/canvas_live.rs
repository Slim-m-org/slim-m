// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A placed canvas object reaching a live socket, and the two things that
//! gate it.
//!
//! `USE_CANVAS` is the reason this file exists. Every other channel-scoped
//! frame is gated on `VIEW_CHANNEL` alone, so the fan-out cache only ever had
//! to remember one bit; a canvas frame needs both, or somebody an overwrite
//! denied the canvas is handed over the socket exactly what
//! `GET /canvas/objects` refuses them. The test below fails if the cache goes
//! back to being a bool.
//!
//! The second is that a canvas burst must stay a canvas burst. The hub is one
//! broadcast channel for the whole deployment, and a lagging subscriber is
//! closed rather than skipped, so a text-only connection sharing that ring
//! with somebody drawing has to survive it.

use std::time::Duration;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::http::{self, AppState};
use slimm_server::ids::{ChannelId, UserId};
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

async fn new_store() -> (Store, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new("slimm-canvas-live");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    (
        Store::new(db::connect(&config).await.expect("connect + migrate")),
        guard,
    )
}

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

fn place_request(channel: ChannelId, token: &str) -> Request<Body> {
    Request::builder()
        .method("POST")
        .uri(format!("/channels/{channel}/canvas/objects"))
        .header("authorization", format!("Bearer {token}"))
        .header("content-type", "application/json")
        .body(Body::from(
            json!({
                "id": Uuid::now_v7().to_string(),
                "kind": "stroke",
                "x": 4.0, "y": 5.0, "w": 6.0, "h": 7.0,
                "props": { "points": [0.0, 0.0, 6.0, 7.0], "width": 3.0, "color": "annotation" },
            })
            .to_string(),
        ))
        .unwrap()
}

fn remove_request(channel: ChannelId, token: &str, object_id: &str) -> Request<Body> {
    Request::builder()
        .method("POST")
        .uri(format!("/channels/{channel}/canvas/ops"))
        .header("authorization", format!("Bearer {token}"))
        .header("content-type", "application/json")
        .body(Body::from(
            json!({
                "id": Uuid::now_v7().to_string(),
                "kind": "remove",
                "object_ids": [object_id],
            })
            .to_string(),
        ))
        .unwrap()
}

fn clear_request(channel: ChannelId, token: &str, before_seq: i64) -> Request<Body> {
    Request::builder()
        .method("POST")
        .uri(format!("/channels/{channel}/canvas/ops"))
        .header("authorization", format!("Bearer {token}"))
        .header("content-type", "application/json")
        .body(Body::from(
            json!({
                "id": Uuid::now_v7().to_string(),
                "kind": "clear",
                "before_seq": before_seq,
            })
            .to_string(),
        ))
        .unwrap()
}

fn move_request(channel: ChannelId, token: &str, object_id: &str) -> Request<Body> {
    Request::builder()
        .method("POST")
        .uri(format!("/channels/{channel}/canvas/ops"))
        .header("authorization", format!("Bearer {token}"))
        .header("content-type", "application/json")
        .body(Body::from(
            json!({
                "id": Uuid::now_v7().to_string(),
                "kind": "move",
                "object_id": object_id,
                "x": 9.0, "y": 9.0, "w": 9.0, "h": 9.0,
            })
            .to_string(),
        ))
        .unwrap()
}

fn reorder_request(channel: ChannelId, token: &str, object_id: &str) -> Request<Body> {
    Request::builder()
        .method("POST")
        .uri(format!("/channels/{channel}/canvas/ops"))
        .header("authorization", format!("Bearer {token}"))
        .header("content-type", "application/json")
        .body(Body::from(
            json!({
                "id": Uuid::now_v7().to_string(),
                "kind": "reorder",
                "object_id": object_id,
                "z_index": 500,
            })
            .to_string(),
        ))
        .unwrap()
}

fn restore_request(channel: ChannelId, token: &str, target_op: &str) -> Request<Body> {
    Request::builder()
        .method("POST")
        .uri(format!("/channels/{channel}/canvas/ops"))
        .header("authorization", format!("Bearer {token}"))
        .header("content-type", "application/json")
        .body(Body::from(
            json!({
                "id": Uuid::now_v7().to_string(),
                "kind": "restore",
                "target_op": target_op,
            })
            .to_string(),
        ))
        .unwrap()
}

/// The load-bearing one. Carol holds `VIEW_CHANNEL` and is denied `USE_CANVAS`
/// by a member overwrite, so she reads the channel and must never be handed a
/// canvas frame; a cache that only remembers the view bit delivers to her.
#[tokio::test]
async fn a_canvas_frame_needs_both_bits_and_a_denied_member_never_sees_one() {
    let (store, _guard) = new_store().await;
    let state = support::app::state(store.clone());
    let (alice_access, alice_ticket, alice) = user_ticket(&store, "alice").await;
    store.bootstrap_deployment(alice).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;

    let (_carol_access, carol_ticket, carol) = user_ticket(&store, "carol").await;
    store
        .set_member_overwrite(channel, carol, Permissions::NONE, Permissions::USE_CANVAS)
        .await
        .unwrap();

    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut carol_ws = connect(addr, &carol_ticket).await;

    let response = http::router(state.clone())
        .oneshot(place_request(channel, &alice_access))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::CREATED);

    let frame = read_frame(&mut alice_ws).await;
    assert_eq!(frame["type"], "canvas.object.placed");
    assert_eq!(frame["channel_id"], channel.to_string());
    assert_eq!(frame["seq"], 1);
    assert_eq!(frame["object"]["kind"], "stroke");
    assert_eq!(frame["object"]["x"], 4.0);

    let carol_next =
        tokio::time::timeout(Duration::from_millis(300), read_frame(&mut carol_ws)).await;
    assert!(
        carol_next.is_err(),
        "carol is denied USE_CANVAS and must not receive canvas frames",
    );
}

/// A retry after a lost response must not repaint the object on every other
/// screen, which is what an unconditional publish would do.
#[tokio::test]
async fn an_idempotent_replay_publishes_nothing() {
    let (store, _guard) = new_store().await;
    let state = support::app::state(store.clone());
    let (access, ticket, alice) = user_ticket(&store, "alice").await;
    store.bootstrap_deployment(alice).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;

    let addr = serve(state.clone()).await;
    let mut ws = connect(addr, &ticket).await;

    let request = place_request(channel, &access);
    let (parts, body) = request.into_parts();
    let bytes = axum::body::to_bytes(body, usize::MAX).await.unwrap();
    let again = Request::from_parts(parts.clone(), Body::from(bytes.clone()));
    let first = Request::from_parts(parts, Body::from(bytes));

    assert_eq!(
        http::router(state.clone())
            .oneshot(first)
            .await
            .unwrap()
            .status(),
        StatusCode::CREATED
    );
    let frame = read_frame(&mut ws).await;
    assert_eq!(frame["type"], "canvas.object.placed");

    assert_eq!(
        http::router(state.clone())
            .oneshot(again)
            .await
            .unwrap()
            .status(),
        StatusCode::CREATED
    );
    let second = tokio::time::timeout(Duration::from_millis(300), read_frame(&mut ws)).await;
    assert!(second.is_err(), "a replay must broadcast nothing");
}

/// The hub is one broadcast channel for the entire deployment and a lagging
/// subscriber is closed, not skipped, so somebody scribbling has to be unable
/// to knock a text-only connection off its socket.
#[tokio::test]
async fn a_canvas_burst_does_not_disconnect_a_text_only_connection() {
    let (store, _guard) = new_store().await;
    let state = support::app::state(store.clone());
    let (alice_access, _alice_ticket, alice) = user_ticket(&store, "alice").await;
    store.bootstrap_deployment(alice).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;

    let (_bob_access, bob_ticket, _bob) = user_ticket(&store, "bob").await;
    let addr = serve(state.clone()).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    for _ in 0..60 {
        let response = http::router(state.clone())
            .oneshot(place_request(channel, &alice_access))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::CREATED);
    }

    let mut seen = 0;
    for _ in 0..60 {
        let frame = read_frame(&mut bob_ws).await;
        assert_ne!(
            frame["type"], "error",
            "the burst closed a connection instead of being delivered",
        );
        if frame["type"] == "canvas.object.placed" {
            seen += 1;
        }
    }
    assert_eq!(seen, 60);
}

/// The same load-bearing property as the placement test above, for the five
/// other frames: a member an overwrite denies `USE_CANVAS` must receive
/// neither a removal, a clear, a restore, a move, nor a reorder, exactly as
/// she receives no placement. Extends the reachability guard `extra_bit`
/// exists for:
/// reverting it to a `matches!` naming only `CanvasObjectPlaced` fails this
/// the moment any one of the five fires.
#[tokio::test]
async fn a_removal_a_clear_a_restore_a_move_and_a_reorder_need_both_bits_and_a_denied_member_never_sees_any()
 {
    let (store, _guard) = new_store().await;
    let state = support::app::state(store.clone());
    let (alice_access, alice_ticket, alice) = user_ticket(&store, "alice").await;
    store.bootstrap_deployment(alice).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;

    let (_carol_access, carol_ticket, carol) = user_ticket(&store, "carol").await;
    store
        .set_member_overwrite(channel, carol, Permissions::NONE, Permissions::USE_CANVAS)
        .await
        .unwrap();

    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut carol_ws = connect(addr, &carol_ticket).await;

    let placed = http::router(state.clone())
        .oneshot(place_request(channel, &alice_access))
        .await
        .unwrap();
    assert_eq!(placed.status(), StatusCode::CREATED);
    let bytes = axum::body::to_bytes(placed.into_body(), usize::MAX)
        .await
        .unwrap();
    let placed: Value = serde_json::from_slice(&bytes).unwrap();
    let object_id = placed["id"].as_str().unwrap().to_owned();
    assert_eq!(
        read_frame(&mut alice_ws).await["type"],
        "canvas.object.placed"
    );

    let removed = http::router(state.clone())
        .oneshot(remove_request(channel, &alice_access, &object_id))
        .await
        .unwrap();
    assert_eq!(removed.status(), StatusCode::CREATED);
    let bytes = axum::body::to_bytes(removed.into_body(), usize::MAX)
        .await
        .unwrap();
    let removed_body: Value = serde_json::from_slice(&bytes).unwrap();
    let remove_op_id = removed_body["op"]["id"].as_str().unwrap().to_owned();
    let frame = read_frame(&mut alice_ws).await;
    assert_eq!(frame["type"], "canvas.objects.removed");
    assert_eq!(frame["channel_id"], channel.to_string());
    assert_eq!(frame["object_ids"], json!([object_id]));

    let cleared = http::router(state.clone())
        .oneshot(clear_request(channel, &alice_access, 1))
        .await
        .unwrap();
    assert_eq!(cleared.status(), StatusCode::CREATED);
    // Nothing is below seq 1 yet, so this is an affected-0 no-op; place a second object to clear for real.
    let placed_again = http::router(state.clone())
        .oneshot(place_request(channel, &alice_access))
        .await
        .unwrap();
    assert_eq!(placed_again.status(), StatusCode::CREATED);
    assert_eq!(
        read_frame(&mut alice_ws).await["type"],
        "canvas.object.placed"
    );

    let cleared = http::router(state.clone())
        .oneshot(clear_request(channel, &alice_access, 100))
        .await
        .unwrap();
    assert_eq!(cleared.status(), StatusCode::CREATED);
    let frame = read_frame(&mut alice_ws).await;
    assert_eq!(frame["type"], "canvas.cleared");
    assert_eq!(frame["before_seq"], 100);

    let restored = http::router(state.clone())
        .oneshot(restore_request(channel, &alice_access, &remove_op_id))
        .await
        .unwrap();
    assert_eq!(restored.status(), StatusCode::CREATED);
    let frame = read_frame(&mut alice_ws).await;
    assert_eq!(frame["type"], "canvas.objects.restored");
    assert_eq!(frame["channel_id"], channel.to_string());
    assert_eq!(frame["object_ids"], json!([object_id]));

    // Restored above, so it is live again and movable.
    let moved = http::router(state.clone())
        .oneshot(move_request(channel, &alice_access, &object_id))
        .await
        .unwrap();
    assert_eq!(moved.status(), StatusCode::CREATED);
    let frame = read_frame(&mut alice_ws).await;
    assert_eq!(frame["type"], "canvas.object.moved");
    assert_eq!(frame["channel_id"], channel.to_string());
    assert_eq!(frame["object_id"], object_id);
    assert_eq!(frame["x"], 9.0);

    let reordered = http::router(state.clone())
        .oneshot(reorder_request(channel, &alice_access, &object_id))
        .await
        .unwrap();
    assert_eq!(reordered.status(), StatusCode::CREATED);
    let frame = read_frame(&mut alice_ws).await;
    assert_eq!(frame["type"], "canvas.object.reordered");
    assert_eq!(frame["channel_id"], channel.to_string());
    assert_eq!(frame["object_id"], object_id);
    assert_eq!(frame["z_index"], 500);

    let carol_next =
        tokio::time::timeout(Duration::from_millis(300), read_frame(&mut carol_ws)).await;
    assert!(
        carol_next.is_err(),
        "carol is denied USE_CANVAS and must receive none of a removal, a clear, a restore, a move, or a reorder",
    );
}

/// An affected-0 op is a real state transition that never happened, so it
/// must not fan a frame out to anybody, the same guarantee an idempotent
/// replay already gets.
#[tokio::test]
async fn an_op_that_changes_nothing_publishes_no_frame() {
    let (store, _guard) = new_store().await;
    let state = support::app::state(store.clone());
    let (alice_access, alice_ticket, alice) = user_ticket(&store, "alice").await;
    store.bootstrap_deployment(alice).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;

    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;

    let response = http::router(state.clone())
        .oneshot(clear_request(channel, &alice_access, 0))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::CREATED);

    let next = tokio::time::timeout(Duration::from_millis(300), read_frame(&mut alice_ws)).await;
    assert!(next.is_err(), "an affected-0 clear must publish nothing");
}
