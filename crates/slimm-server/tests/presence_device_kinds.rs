// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Presence reports which kinds of client a member is connected from: the set
//! follows the live sockets over the wire and REST, and a member who appears
//! offline leaks none of it.

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
    let (path, guard) = support::TestDbGuard::new("slimm-presence-test");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool), guard)
}

fn state_for(store: &Store, hub: Hub) -> AppState {
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

/// Opens a session whose device signed in as `client_kind` and mints its ws ticket.
async fn ticket_as(
    store: &Store,
    user: slimm_server::ids::UserId,
    client_kind: Option<&str>,
) -> (String, String) {
    let tokens = store
        .open_session_as(user, "device", client_kind, None, None)
        .await
        .unwrap();
    let ctx = store
        .authenticate(&tokens.access_token)
        .await
        .unwrap()
        .unwrap();
    let (ticket, _expires_at) = store.mint_ws_ticket(&ctx).await.unwrap();
    (tokens.access_token, ticket)
}

async fn new_user(store: &Store, name: &str) -> slimm_server::ids::UserId {
    store.create_user(name, name).await.unwrap().id
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

fn request(method: &str, uri: &str, token: &str, body: Option<Value>) -> Request<Body> {
    let builder = Request::builder()
        .method(method)
        .uri(uri)
        .header("authorization", format!("Bearer {token}"));
    match body {
        Some(body) => builder
            .header("content-type", "application/json")
            .body(Body::from(body.to_string()))
            .unwrap(),
        None => builder.body(Body::empty()).unwrap(),
    }
}

async fn send(state: &AppState, req: Request<Body>) -> StatusCode {
    http::router(state.clone())
        .oneshot(req)
        .await
        .unwrap()
        .status()
}

async fn devices_over_rest(state: &AppState, token: &str, target: &str) -> Value {
    let response = http::router(state.clone())
        .oneshot(
            Request::builder()
                .uri(format!("/presence?ids={target}"))
                .header("authorization", format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    serde_json::from_slice::<Value>(&bytes).unwrap()[0].clone()
}

#[tokio::test]
async fn presence_lists_the_client_kinds_of_every_live_socket() {
    let (store, _guard) = new_store().await;
    let state = state_for(&store, Hub::new());
    let addr = serve(state.clone()).await;
    let alice = new_user(&store, "alice").await;
    let bob = new_user(&store, "bob").await;
    let alice_id = alice.to_string();
    let (bob_access, bob_ticket) = ticket_as(&store, bob, Some("desktop")).await;

    let mut bob_ws = connect(addr, &bob_ticket).await;
    let (_a, phone_ticket) = ticket_as(&store, alice, Some("ios")).await;
    let phone = connect(addr, &phone_ticket).await;
    let frame = next_presence_for(&mut bob_ws, &alice_id).await;
    assert_eq!(frame["devices"], json!(["mobile"]));
    assert_eq!(
        devices_over_rest(&state, &bob_access, &alice_id).await["devices"],
        json!(["mobile"])
    );

    let (_a, desktop_ticket) = ticket_as(&store, alice, Some("desktop")).await;
    let desktop = connect(addr, &desktop_ticket).await;
    let frame = next_presence_for(&mut bob_ws, &alice_id).await;
    assert_eq!(frame["devices"], json!(["mobile", "desktop"]));
    assert_eq!(
        devices_over_rest(&state, &bob_access, &alice_id).await["devices"],
        json!(["mobile", "desktop"])
    );

    drop(desktop);
    let frame = next_presence_for(&mut bob_ws, &alice_id).await;
    assert_eq!(frame["devices"], json!(["mobile"]));
    drop(phone);
    let frame = next_presence_for(&mut bob_ws, &alice_id).await;
    assert_eq!(frame["status"], "offline");
    assert!(frame.get("devices").is_none());
}

#[tokio::test]
async fn a_session_with_no_recorded_kind_reads_as_unknown() {
    let (store, _guard) = new_store().await;
    let state = state_for(&store, Hub::new());
    let addr = serve(state.clone()).await;
    let alice = new_user(&store, "alice").await;
    let bob = new_user(&store, "bob").await;
    let (_a, alice_ticket) = ticket_as(&store, alice, None).await;
    let (bob_access, _t) = ticket_as(&store, bob, None).await;
    let _old = connect(addr, &alice_ticket).await;
    let entry = devices_over_rest(&state, &bob_access, &alice.to_string()).await;
    assert_eq!(entry["devices"], json!(["unknown"]));
}

#[tokio::test]
async fn an_appear_offline_member_leaks_no_client_kind() {
    let (store, _guard) = new_store().await;
    let state = state_for(&store, Hub::new());
    let addr = serve(state.clone()).await;
    let alice = new_user(&store, "alice").await;
    let bob = new_user(&store, "bob").await;
    let alice_id = alice.to_string();
    let (alice_access, alice_ticket) = ticket_as(&store, alice, Some("android")).await;
    let (bob_access, _t) = ticket_as(&store, bob, None).await;
    let status = send(
        &state,
        request(
            "PATCH",
            "/presence",
            &alice_access,
            Some(json!({ "visibility": "hidden" })),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let _phone = connect(addr, &alice_ticket).await;

    let to_bob = devices_over_rest(&state, &bob_access, &alice_id).await;
    assert_eq!(to_bob["status"], "offline");
    assert!(to_bob.get("devices").is_none());
    let to_self = devices_over_rest(&state, &alice_access, &alice_id).await;
    assert_eq!(to_self["devices"], json!(["mobile"]));
}
