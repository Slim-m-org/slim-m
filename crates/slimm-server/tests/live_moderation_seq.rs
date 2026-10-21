// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Moderation events carry a number and the connect `hello` carries the head,
//! so a consumer that was offline can tell it missed some. See
//! `hub::moderation_seq`.

use axum::body::Body;
use axum::http::{Request, StatusCode};
use futures_util::SinkExt;
use serde_json::{Value, json};
use slimm_server::http::{self, AppState};
use slimm_server::store::Store;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message as WsMessage;
use tower::ServiceExt;

mod support;

use support::ws::{Client, read_frame_skipping_presence_timed, serve};

/// Creates a user and returns (rest access token, ws connect ticket, user id).
async fn ticket_for(store: &Store, user: slimm_server::ids::UserId) -> String {
    let tokens = store.open_session(user, "device").await.unwrap();
    let ctx = store
        .authenticate(&tokens.access_token)
        .await
        .unwrap()
        .unwrap();
    store.mint_ws_ticket(&ctx).await.unwrap().0
}

async fn connect(addr: std::net::SocketAddr, ticket: &str) -> (Client, Value) {
    let (mut ws, _response) = connect_async(format!("ws://{addr}/ws")).await.unwrap();
    ws.send(WsMessage::Text(
        json!({ "type": "hello", "ticket": ticket, "protocol": 1 }).to_string(),
    ))
    .await
    .unwrap();
    let ack = read_frame_skipping_presence_timed(&mut ws).await;
    assert_eq!(ack["type"], "hello");
    (ws, ack)
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

async fn timeout(state: &AppState, admin_token: &str, target: slimm_server::ids::UserId) {
    let response = http::router(state.clone())
        .oneshot(req(
            "PUT",
            &format!("/members/{target}/timeout"),
            admin_token,
            Some(json!({ "duration_seconds": 60 })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
}

/// A bot that was offline for a timeout reconnects to a head past the last
/// number it saw, which is the signal that its trail has a hole.
#[tokio::test]
async fn a_reconnect_after_a_missed_moderation_event_sees_a_later_head() {
    let (store, _guard) = support::new_store("slimm-live-moderation-seq-test").await;
    let admin = store.create_account("admin", "Admin", "x").await.unwrap();
    store.bootstrap_deployment(admin.id).await.unwrap();
    let admin_token = store
        .open_session(admin.id, "cli")
        .await
        .unwrap()
        .access_token;
    let bot = store.create_user("bot", "bot").await.unwrap();
    let victim = store.create_user("victim", "victim").await.unwrap();
    let state = support::app::state(store.clone());
    let addr = serve(state.clone()).await;

    let (ws, first_hello) = connect(addr, &ticket_for(&store, bot.id).await).await;
    let last_seen = first_hello["moderation_seq"]
        .as_u64()
        .expect("hello carries the head");
    drop(ws);

    timeout(&state, &admin_token, victim.id).await;

    let (mut ws, second_hello) = connect(addr, &ticket_for(&store, bot.id).await).await;
    let head = second_hello["moderation_seq"].as_u64().unwrap();
    assert!(
        head > last_seen,
        "a missed event must move the head: {head} vs {last_seen}"
    );

    timeout(&state, &admin_token, victim.id).await;
    let frame = read_frame_skipping_presence_timed(&mut ws).await;
    assert_eq!(frame["type"], "member.timeout");
    assert!(
        frame["seq"].as_u64().unwrap() > head,
        "a live event is numbered past the head: {frame}"
    );
}

/// With nothing moderated in between, a reconnect sees the same head, so a
/// quiet gap is not reported as a hole.
#[tokio::test]
async fn a_quiet_reconnect_sees_the_same_head() {
    let (store, _guard) = support::new_store("slimm-live-moderation-seq-test").await;
    let bot = store.create_user("bot", "bot").await.unwrap();
    let addr = serve(support::app::state(store.clone())).await;

    let (ws, first) = connect(addr, &ticket_for(&store, bot.id).await).await;
    drop(ws);
    let (_ws, second) = connect(addr, &ticket_for(&store, bot.id).await).await;
    assert_eq!(first["moderation_seq"], second["moderation_seq"]);
}

/// Every one of the five events is numbered, past the hello head and past the one before it.
#[tokio::test]
async fn each_moderation_event_carries_an_increasing_seq() {
    use slimm_server::hub::Event;
    use slimm_server::ids::{RoleId, UserId};

    let (store, _guard) = support::new_store("slimm-live-moderation-seq-test").await;
    let bot = store.create_user("bot", "bot").await.unwrap();
    let state = support::app::state(store.clone());
    let addr = serve(state.clone()).await;
    let (mut ws, hello) = connect(addr, &ticket_for(&store, bot.id).await).await;
    let mut last = hello["moderation_seq"].as_u64().unwrap();

    let events = [
        (
            "member.timeout",
            Event::MemberTimeoutChanged {
                user_id: UserId::generate(),
                until: Some(1),
            },
        ),
        ("member.removed", Event::MemberRemoved(UserId::generate())),
        ("member.restored", Event::MemberRestored(UserId::generate())),
        (
            "member.role_changed",
            Event::MemberRoleChanged {
                user_id: UserId::generate(),
                role_id: RoleId::generate(),
            },
        ),
        (
            "role.changed",
            Event::RoleChanged {
                role_id: RoleId::generate(),
            },
        ),
    ];
    for (kind, event) in events {
        state.hub.publish(event);
        let frame = read_frame_skipping_presence_timed(&mut ws).await;
        assert_eq!(frame["type"], kind);
        let seq = frame["seq"]
            .as_u64()
            .unwrap_or_else(|| panic!("{kind} carries no seq: {frame}"));
        assert!(seq > last, "{kind} seq {seq} is not past {last}");
        last = seq;
    }
}
