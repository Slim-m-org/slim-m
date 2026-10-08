// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! End-to-end WebSocket tests against a real server on an ephemeral port, driven
//! by a real WebSocket client. Covers the two-client fan-out and ordering and
//! the per-event permission filter, including a store error while resolving
//! it, and the durable/ephemeral channel split's lag behavior. Session-lifecycle
//! closes (logout, device removal, account deletion, a bad ticket) live in
//! `tests/ws_session_lifecycle.rs`.

use std::sync::Arc;
use std::time::Duration;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::http::{self, AppState};
use slimm_server::hub::{Event, Hub};
use slimm_server::ids::MessageId;
use slimm_server::permissions::Permissions;
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::{NewMessage, Store};
use sqlx::SqlitePool;
use tokio::net::TcpListener;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message as WsMessage;
use tower::ServiceExt;
use uuid::Uuid;

mod support;

type Client =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

async fn new_store() -> (Store, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new("slimm-ws-test");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool), guard)
}

/// Like [`new_store`], but also hands back the raw pool so a test can break a
/// single query for real; see
/// `a_store_error_authorizing_fan_out_closes_the_connection`.
async fn new_store_with_pool() -> (Store, SqlitePool, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new("slimm-ws-test");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool.clone()), pool, guard)
}

fn state_for(store: &Store) -> AppState {
    AppState {
        store: store.clone(),
        auth: Auth::new(2).unwrap(),
        hub: Hub::new(),
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

/// Spawns the real server and returns its address.
async fn serve(state: AppState) -> std::net::SocketAddr {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(listener, http::router(state)).await.unwrap();
    });
    addr
}

/// Connects, performs the hello handshake, and returns the live socket.
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

/// Reads the next text frame as JSON, skipping any control frames.
///
/// Also skips `presence.changed`, which every connect and disconnect publishes
/// on the shared hub (`presence.rs` covers it), and `read_state.changed`,
/// which a send publishes for its author (`read_state_devices.rs` covers it).
async fn read_frame(ws: &mut Client) -> Value {
    loop {
        match ws.next().await {
            Some(Ok(WsMessage::Text(text))) => {
                let frame: Value = serde_json::from_str(text.as_str()).unwrap();
                let kind = frame["type"].as_str().unwrap_or_default();
                if kind == "presence.changed" || kind == "read_state.changed" {
                    continue;
                }
                return frame;
            }
            Some(Ok(_)) => continue,
            other => panic!("expected a text frame, got {other:?}"),
        }
    }
}

/// Resolves once the socket has closed (a close frame, end of stream, or error).
async fn wait_closed(ws: &mut Client) {
    loop {
        match ws.next().await {
            None | Some(Ok(WsMessage::Close(_))) | Some(Err(_)) => return,
            Some(Ok(_)) => continue,
        }
    }
}

fn send_request(uri: &str, token: &str, body: Value) -> Request<Body> {
    Request::builder()
        .method("POST")
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .header("content-type", "application/json")
        .body(Body::from(body.to_string()))
        .unwrap()
}

#[tokio::test]
async fn two_clients_receive_fan_out_in_order() {
    let (store, _guard) = new_store().await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let state = state_for(&store);

    let (alice_access, alice_ticket, _alice) = user_ticket(&store, "alice").await;
    let (_bob_access, bob_ticket, _bob) = user_ticket(&store, "bob").await;

    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    // A REST send on a router sharing the same hub reaches both connections.
    let uri = format!("/channels/{}/messages", channel.id);
    let response = http::router(state.clone())
        .oneshot(send_request(
            &uri,
            &alice_access,
            json!({ "id": Uuid::now_v7().to_string(), "content": "hello everyone" }),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);

    for ws in [&mut alice_ws, &mut bob_ws] {
        let frame = read_frame(ws).await;
        assert_eq!(frame["type"], "message.created");
        assert_eq!(frame["seq"], 1);
        assert_eq!(frame["message"]["content"], "hello everyone");
    }
}

#[tokio::test]
async fn fan_out_respects_view_permission() {
    let (store, _guard) = new_store().await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let state = state_for(&store);

    let (alice_access, alice_ticket, _alice) = user_ticket(&store, "alice").await;
    let (_bob_access, bob_ticket, bob) = user_ticket(&store, "bob").await;

    // Deny bob the view of this channel specifically.
    store
        .set_member_overwrite(
            channel.id,
            bob,
            Permissions::NONE,
            Permissions::VIEW_CHANNEL,
        )
        .await
        .unwrap();

    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    let uri = format!("/channels/{}/messages", channel.id);
    http::router(state.clone())
        .oneshot(send_request(
            &uri,
            &alice_access,
            json!({ "id": Uuid::now_v7().to_string(), "content": "members only" }),
        ))
        .await
        .unwrap();

    // Alice, who can view, receives it.
    let frame = read_frame(&mut alice_ws).await;
    assert_eq!(frame["type"], "message.created");

    // Bob, denied view of this channel, receives nothing within a short window.
    let bob_next = tokio::time::timeout(Duration::from_millis(300), read_frame(&mut bob_ws)).await;
    assert!(bob_next.is_err(), "bob must not receive a hidden channel");
}

/// A store error while resolving the fan-out permission check must not read
/// as "not visible" and be silently dropped: `/sync` filters purely by seq,
/// so a connection whose cursor has already moved past a dropped event can
/// never recover it short of a full channel reset. The connection closes
/// instead, onto the same resync path a lagged subscriber already takes.
///
/// The message is sent through `Store::send_message` directly rather than the
/// REST handler, and the column is broken before that call rather than after:
/// the REST handler's own permission check reads the identical query, so
/// breaking it first (rather than racing the handler's send against the
/// asynchronous fan-out) is what makes this deterministic instead of racy.
#[tokio::test]
async fn a_store_error_authorizing_fan_out_closes_the_connection() {
    let (store, pool, _guard) = new_store_with_pool().await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let state = state_for(&store);

    let (_alice_access, _alice_ticket, alice) = user_ticket(&store, "alice").await;
    let (_bob_access, bob_ticket, _bob) = user_ticket(&store, "bob").await;

    let addr = serve(state.clone()).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    sqlx::query("ALTER TABLE channels RENAME COLUMN topic TO topic_broken")
        .execute(&pool)
        .await
        .expect("break the column permissions_in_channel queries by name");

    let sent = store
        .send_message(NewMessage::plain(
            channel.id,
            alice,
            MessageId::generate(),
            "hello",
        ))
        .await
        .unwrap();
    state.hub.publish(Event::MessageCreated {
        message: Arc::new(sent.message),
        attachments: Arc::new(Vec::new()),
        forwarded: None,
        app_surface: None,
        code_run: None,
        poll: None,
        embeds: Arc::new(Vec::new()),
        call: None,
        components: Arc::new(Vec::new()),
        lookups: Default::default(),
    });

    let closed = tokio::time::timeout(Duration::from_secs(2), wait_closed(&mut bob_ws)).await;
    assert!(
        closed.is_ok(),
        "a store error authorizing fan-out must close the connection, not drop the message"
    );
}

/// A burst of cursor events that outruns the ephemeral channel's own capacity
/// must not close the connection or force a resync: dropping a stale cursor
/// is the entire point of splitting it from the durable channel (see
/// `crate::hub`'s own doc comment). Bob's connection skips forward on the
/// ephemeral channel and keeps serving the durable one exactly as before.
///
/// The burst is a tight loop with no `.await` between sends. `#[tokio::test]`
/// defaults to a current-thread runtime, so bob's connection task cannot run
/// at all until this test task yields - the only way to make the channel's
/// own overflow deterministic rather than a race against however fast the
/// connection happens to get scheduled.
#[tokio::test]
async fn ephemeral_lag_skips_forward_without_closing_or_blocking_durable_events() {
    let (store, _guard) = new_store().await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL
                .union(Permissions::SEND_MESSAGES)
                .union(Permissions::USE_CANVAS),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let state = state_for(&store);

    let (alice_access, _alice_ticket, alice) = user_ticket(&store, "alice").await;
    let (_bob_access, bob_ticket, _bob) = user_ticket(&store, "bob").await;

    let addr = serve(state.clone()).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    // Comfortably past any plausible ephemeral capacity, not tied to the exact tuning.
    for _ in 0..5_000 {
        state.hub.publish(Event::CanvasCursorMoved {
            channel_id: channel.id,
            user_id: alice,
            x: 0.0,
            y: 0.0,
        });
    }

    let uri = format!("/channels/{}/messages", channel.id);
    let response = http::router(state.clone())
        .oneshot(send_request(
            &uri,
            &alice_access,
            json!({ "id": Uuid::now_v7().to_string(), "content": "still here" }),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);

    // A leftover cursor frame may still surface here; only the durable arrival matters.
    let message_frame = loop {
        let frame = read_frame(&mut bob_ws).await;
        assert_ne!(
            frame["type"], "error",
            "an ephemeral-channel lag must never surface a resync error: {frame}"
        );
        if frame["type"] == "canvas.cursor.moved" {
            continue;
        }
        break frame;
    };
    assert_eq!(
        message_frame["type"], "message.created",
        "the durable event must still arrive after an ephemeral-channel lag: {message_frame}"
    );
    assert_eq!(message_frame["message"]["content"], "still here");
}

/// The mirror of the test above: a lag on the *durable* channel is unchanged
/// by this split and still forces the existing resync-and-close path, since a
/// dropped message, role change or membership change cannot be silently
/// skipped the way a stale cursor can.
#[tokio::test]
async fn durable_lag_still_forces_a_resync_close() {
    let (store, _guard) = new_store().await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let state = state_for(&store);

    let (_bob_access, bob_ticket, _bob) = user_ticket(&store, "bob").await;

    let addr = serve(state.clone()).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    // Comfortably past any plausible durable capacity; see the test above for the tight-loop reason.
    for _ in 0..5_000 {
        state.hub.publish(Event::MessageDeleted {
            channel_id: channel.id,
            message_id: MessageId::generate(),
            op_seq: None,
        });
    }

    let frame = read_frame(&mut bob_ws).await;
    assert_eq!(frame["type"], "error");
    assert_eq!(frame["message"], "resync");

    let closed = tokio::time::timeout(Duration::from_secs(2), wait_closed(&mut bob_ws)).await;
    assert!(
        closed.is_ok(),
        "a durable-channel lag must still close the connection"
    );
}
