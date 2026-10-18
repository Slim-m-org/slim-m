// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! MOD7: `Event::ReportsChanged` reaching a moderator's live connection when
//! a report is filed or resolved, and - the security assertion this exists
//! to prove - reaching nobody else.
//!
//! `Report` (`crate::store::Report`) carries the reported content verbatim,
//! so the frame itself carries nothing at all; what has to hold is that a
//! non-moderator connection never even receives the empty envelope. See
//! `hub::Event::ReportsChanged` and `http::ws::authorization::authorize`'s
//! own gate for it.

use std::time::Duration;

use axum::http::StatusCode;
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

use support::app::request_json as request;

type Client =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

/// Creates a user and returns (rest access token, ws connect ticket, user id).
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

/// Reads the next text frame this test cares about: control frames are
/// skipped, and so is `presence.changed`, the same chatter `tests/ws.rs`
/// filters for the same reason (every connect/disconnect here publishes one
/// on the shared hub).
async fn read_frame(ws: &mut Client) -> Value {
    loop {
        match ws.next().await {
            Some(Ok(WsMessage::Text(text))) => {
                let frame: Value = serde_json::from_str(text.as_str()).unwrap();
                // The author's own read marker moves with every send; not what this file measures.
                if frame["type"] == "presence.changed" || frame["type"] == "read_state.changed" {
                    continue;
                }
                return frame;
            }
            Some(Ok(_)) => continue,
            other => panic!("expected a text frame, got {other:?}"),
        }
    }
}

/// Waits up to `within` for a non-`presence.changed` frame; `None` means
/// nothing arrived, which is the assertion every "receives nothing" case
/// below is checking.
async fn frame_within(ws: &mut Client, within: Duration) -> Option<Value> {
    tokio::time::timeout(within, read_frame(ws)).await.ok()
}

/// The two roles every test here needs: `everyone` (view + send, granted to
/// every user created afterwards) and `moderator` (`MANAGE_MESSAGES` alone,
/// assigned explicitly).
async fn seed_roles(store: &Store) -> slimm_server::ids::RoleId {
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    store
        .create_role("moderator", Permissions::MANAGE_MESSAGES, false)
        .await
        .unwrap()
}

#[tokio::test]
async fn a_moderator_sees_a_filed_report_live_and_a_non_moderator_sees_nothing() {
    let (store, _guard) = support::new_store("slimm-reports-changed-ws").await;
    let moderator_role = seed_roles(&store).await;
    let channel = store.create_channel("general", "text").await.unwrap();
    let state = support::app::state(store.clone());

    let (alice_access, alice_ticket, alice) = user_ticket(&store, "alice").await;
    store.assign_role(alice, moderator_role).await.unwrap();
    let (bob_access, bob_ticket, _bob) = user_ticket(&store, "bob").await;

    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    // Alice authors the message and bob reports it; either way, the queue changed.
    let sent = axum::body::to_bytes(
        http::router(state.clone())
            .oneshot(request(
                "POST",
                &format!("/channels/{}/messages", channel.id),
                &alice_access,
                json!({ "id": Uuid::now_v7().to_string(), "content": "look at this" }),
            ))
            .await
            .unwrap()
            .into_body(),
        usize::MAX,
    )
    .await
    .unwrap();
    let message_id = serde_json::from_slice::<Value>(&sent).unwrap()["id"]
        .as_str()
        .unwrap()
        .to_owned();

    // Both sockets first drain the `message.created` fan-out from the send above, which both alice and bob can see.
    for ws in [&mut alice_ws, &mut bob_ws] {
        let frame = read_frame(ws).await;
        assert_eq!(frame["type"], "message.created");
    }

    let filed = http::router(state.clone())
        .oneshot(request(
            "POST",
            "/reports",
            &bob_access,
            json!({ "subject_kind": "message", "subject_id": message_id, "reason": "spam" }),
        ))
        .await
        .unwrap();
    assert_eq!(filed.status(), StatusCode::OK);

    // Alice, a moderator, sees the queue changed live.
    let alice_frame = frame_within(&mut alice_ws, Duration::from_secs(2)).await;
    assert_eq!(
        alice_frame.as_ref().map(|f| f["type"].clone()),
        Some(Value::String("reports.changed".into())),
        "a moderator must see the filed report live: {alice_frame:?}"
    );

    // Bob, who is not a moderator, receives nothing at all within a short window: the security proof this event exists for.
    let bob_frame = frame_within(&mut bob_ws, Duration::from_millis(300)).await;
    assert!(
        bob_frame.is_none(),
        "a non-moderator must receive nothing on a filed report: {bob_frame:?}"
    );
}

#[tokio::test]
async fn a_moderator_sees_a_resolved_report_live_and_a_non_moderator_sees_nothing() {
    let (store, _guard) = support::new_store("slimm-reports-changed-ws").await;
    let moderator_role = seed_roles(&store).await;
    let channel = store.create_channel("general", "text").await.unwrap();
    let state = support::app::state(store.clone());

    let (alice_access, alice_ticket, alice) = user_ticket(&store, "alice").await;
    store.assign_role(alice, moderator_role).await.unwrap();
    let (bob_access, bob_ticket, _bob) = user_ticket(&store, "bob").await;

    // File the report before either socket connects, so its own fan-out is not what this test is measuring.
    let sent = axum::body::to_bytes(
        http::router(state.clone())
            .oneshot(request(
                "POST",
                &format!("/channels/{}/messages", channel.id),
                &alice_access,
                json!({ "id": Uuid::now_v7().to_string(), "content": "look at this" }),
            ))
            .await
            .unwrap()
            .into_body(),
        usize::MAX,
    )
    .await
    .unwrap();
    let message_id = serde_json::from_slice::<Value>(&sent).unwrap()["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let filed = axum::body::to_bytes(
        http::router(state.clone())
            .oneshot(request(
                "POST",
                "/reports",
                &bob_access,
                json!({ "subject_kind": "message", "subject_id": message_id, "reason": "spam" }),
            ))
            .await
            .unwrap()
            .into_body(),
        usize::MAX,
    )
    .await
    .unwrap();
    let report_id = serde_json::from_slice::<Value>(&filed).unwrap()["id"]
        .as_str()
        .unwrap()
        .to_owned();

    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    let resolved = http::router(state.clone())
        .oneshot(request(
            "PATCH",
            &format!("/reports/{report_id}"),
            &alice_access,
            json!({ "resolution": "resolved" }),
        ))
        .await
        .unwrap();
    assert_eq!(resolved.status(), StatusCode::NO_CONTENT);

    let alice_frame = frame_within(&mut alice_ws, Duration::from_secs(2)).await;
    assert_eq!(
        alice_frame.as_ref().map(|f| f["type"].clone()),
        Some(Value::String("reports.changed".into())),
        "a moderator must see a resolution live: {alice_frame:?}"
    );

    let bob_frame = frame_within(&mut bob_ws, Duration::from_millis(300)).await;
    assert!(
        bob_frame.is_none(),
        "a non-moderator must receive nothing on a resolution either: {bob_frame:?}"
    );
}
