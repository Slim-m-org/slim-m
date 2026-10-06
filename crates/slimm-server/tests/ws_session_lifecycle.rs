// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! End-to-end tests for the ways a session's live socket dies: logout,
//! device removal, account deletion, bot revocation, and a bad connect
//! ticket. Split out of `tests/ws.rs`, which stayed focused on fan-out and
//! delivery.

use std::time::Duration;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::Store;
use tokio::net::TcpListener;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message as WsMessage;
use tower::ServiceExt;

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

const PASSWORD: &str = "correct-horse-battery";

/// Creates a user and returns (rest access token, ws connect ticket, user id).
async fn user_ticket(store: &Store, name: &str) -> (String, String, slimm_server::ids::UserId) {
    let hash = Auth::new(2)
        .unwrap()
        .hash_password(PASSWORD.to_owned())
        .await
        .unwrap();
    let user = store.create_account(name, name, &hash).await.unwrap();
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

/// Resolves once the socket has closed (a close frame, end of stream, or error).
async fn wait_closed(ws: &mut Client) {
    loop {
        match ws.next().await {
            None | Some(Ok(WsMessage::Close(_))) | Some(Err(_)) => return,
            Some(Ok(_)) => continue,
        }
    }
}

#[tokio::test]
async fn logout_closes_the_live_socket() {
    let (store, _guard) = new_store().await;
    let state = state_for(&store);
    let (alice_access, alice_ticket, _alice) = user_ticket(&store, "alice").await;

    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;

    // Log out over REST; the shared hub carries the revocation to the socket.
    let response = http::router(state.clone())
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/auth/logout")
                .header("authorization", format!("Bearer {alice_access}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    // The socket closes promptly rather than lingering with fan-out access.
    let closed = tokio::time::timeout(Duration::from_secs(2), wait_closed(&mut alice_ws)).await;
    assert!(closed.is_ok(), "the socket should close after logout");
}

/// Revoking a bot is the documented answer to a leaked bot token, which never
/// rotates and lives in a container env var. The REST side always worked; the
/// socket did not, because the handler marked the row and published nothing, so
/// an attacker who had already connected kept receiving every event the bot
/// could see for as long as they held the socket open. `Store::revoke_bot`
/// returns the sessions it revoked precisely so this cannot silently regress.
#[tokio::test]
async fn revoking_a_bot_closes_its_live_socket() {
    let (store, _guard) = new_store().await;
    let state = state_for(&store);

    let admin = store
        .create_account("root", "Root", "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(admin.id).await.unwrap();
    let admin_token = store
        .open_session(admin.id, "cli")
        .await
        .unwrap()
        .access_token;

    let addr = serve(state.clone()).await;
    let created = http::router(state.clone())
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/bots")
                .header("authorization", format!("Bearer {admin_token}"))
                .header("content-type", "application/json")
                .body(Body::from(json!({ "username": "helper" }).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(created.status(), StatusCode::CREATED);
    let bytes = axum::body::to_bytes(created.into_body(), usize::MAX)
        .await
        .unwrap();
    let body: Value = serde_json::from_slice(&bytes).unwrap();
    let bot_id = body["bot"]["user_id"].as_str().unwrap().to_owned();
    let bot_token = body["token"].as_str().unwrap().to_owned();

    let ctx = store
        .authenticate_bot(&bot_token)
        .await
        .unwrap()
        .expect("a fresh bot token authenticates");
    let (ticket, _expires_at) = store.mint_ws_ticket(&ctx).await.unwrap();
    let mut bot_ws = connect(addr, &ticket).await;

    let revoked = http::router(state.clone())
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/bots/{bot_id}/revoke"))
                .header("authorization", format!("Bearer {admin_token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(revoked.status(), StatusCode::NO_CONTENT);

    let closed = tokio::time::timeout(Duration::from_secs(2), wait_closed(&mut bot_ws)).await;
    assert!(
        closed.is_ok(),
        "revoking a bot must close the socket it already holds, not just stop the next request"
    );
}

/// Removing a device is the third way a session dies, alongside logout and
/// account deletion, and the only one with no test until now.
///
/// `Store::remove_device` deliberately does not publish anything itself: the
/// handler does, because it is the layer that holds the hub. That split is
/// easy to undo by accident while refactoring, and nothing would fail.
#[tokio::test]
async fn removing_a_device_closes_its_live_socket() {
    let (store, _guard) = new_store().await;
    let state = state_for(&store);
    let (alice_access, alice_ticket, alice) = user_ticket(&store, "alice").await;

    // A second device, whose socket must survive: the revocation is per-session.
    let other = store.open_session(alice, "phone").await.unwrap();
    let other_ctx = store
        .authenticate(&other.access_token)
        .await
        .unwrap()
        .unwrap();
    let (other_ticket, _) = store.mint_ws_ticket(&other_ctx).await.unwrap();

    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut other_ws = connect(addr, &other_ticket).await;

    let device = store
        .authenticate(&alice_access)
        .await
        .unwrap()
        .unwrap()
        .device_id;
    let response = http::router(state.clone())
        .oneshot(
            Request::builder()
                .method("DELETE")
                .uri(format!("/devices/{device}"))
                .header("authorization", format!("Bearer {}", other.access_token))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    let closed = tokio::time::timeout(Duration::from_secs(2), wait_closed(&mut alice_ws)).await;
    assert!(
        closed.is_ok(),
        "the removed device's socket must close, not linger with fan-out access"
    );

    // The surviving device keeps its socket, so the revocation was targeted.
    let still_open =
        tokio::time::timeout(Duration::from_millis(400), wait_closed(&mut other_ws)).await;
    assert!(
        still_open.is_err(),
        "removing one device must not close another device's socket"
    );
}

#[tokio::test]
async fn a_bad_ticket_is_rejected() {
    let (store, _guard) = new_store().await;
    let addr = serve(state_for(&store)).await;

    let (mut ws, _response) = connect_async(format!("ws://{addr}/ws")).await.unwrap();
    ws.send(WsMessage::Text(
        json!({ "type": "hello", "ticket": "not-a-real-ticket", "protocol": 1 }).to_string(),
    ))
    .await
    .unwrap();

    let frame = read_frame(&mut ws).await;
    assert_eq!(frame["type"], "error");
}

/// Deleting an account revokes its sessions and publishes the same event
/// logout does, but only logout had a test proving a live socket actually
/// closes. Deletion is the path where a socket left attached would keep
/// delivering a channel's messages to an account that no longer exists.
#[tokio::test]
async fn deleting_the_account_closes_its_live_socket() {
    let (store, _guard) = new_store().await;
    let state = state_for(&store);
    let (alice_access, alice_ticket, _alice) = user_ticket(&store, "alice").await;

    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;

    let response = http::router(state.clone())
        .oneshot(
            Request::builder()
                .method("DELETE")
                .uri("/account")
                .header("authorization", format!("Bearer {alice_access}"))
                .header("content-type", "application/json")
                .body(Body::from(format!(r#"{{"password":"{PASSWORD}"}}"#)))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    let closed = tokio::time::timeout(Duration::from_secs(2), wait_closed(&mut alice_ws)).await;
    assert!(
        closed.is_ok(),
        "the socket must close when the account behind it is deleted"
    );
}

/// A revocation published while the socket is still waiting to say hello must
/// still close it, so the durable subscription has to exist before the ticket
/// is redeemed rather than after.
#[tokio::test]
async fn a_revocation_before_the_hello_still_closes_the_socket() {
    let (store, _guard) = new_store().await;
    let state = state_for(&store);
    let (access, ticket, _user) = user_ticket(&store, "alice").await;
    let session = store
        .authenticate(&access)
        .await
        .unwrap()
        .unwrap()
        .session_id;

    let addr = serve(state.clone()).await;
    let (mut ws, _response) = connect_async(format!("ws://{addr}/ws")).await.unwrap();
    // The server task subscribes as soon as the upgrade lands; give it that.
    tokio::time::sleep(Duration::from_millis(200)).await;
    state
        .hub
        .publish(slimm_server::hub::Event::SessionRevoked(session));
    ws.send(WsMessage::Text(
        json!({ "type": "hello", "ticket": ticket, "protocol": 1 }).to_string(),
    ))
    .await
    .unwrap();

    let closed = tokio::time::timeout(Duration::from_secs(2), wait_closed(&mut ws)).await;
    assert!(
        closed.is_ok(),
        "the socket should close for a revoked session"
    );
}
