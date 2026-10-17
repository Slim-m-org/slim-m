// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! End-to-end coverage for the `RoleChanged` and `MemberRoleChanged` events,
//! half of the 2026-07-30 audit's fan-out finding that was missing entirely
//! (`hub.publish` never appeared in `http/roles.rs`). See `live_channel_events.rs`
//! for the channel and overwrite half of the same finding.
//!
//! Both events broadcast to every connection: neither ever carries a role's
//! name or bits (the only privileged part of a role), matching the doc
//! comments on `hub::Event::RoleChanged` and `hub::Event::MemberRoleChanged`.

use std::time::Duration;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::permissions::Permissions;
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

/// Reads the next text frame as JSON, skipping `presence.changed`: every
/// connect in this file publishes one on the same shared hub these tests
/// assert against, and it is real chatter no test here is checking.
///
/// Bounded rather than a bare loop: a missing publish must fail this test
/// fast with a clear panic, not hang the runner forever waiting for a frame
/// that will never come.
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

async fn json_body(response: axum::response::Response) -> Value {
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    serde_json::from_slice(&bytes).unwrap()
}

/// Grants ADMINISTRATOR to a user so every test below can create, update, and
/// delete roles and assign or unassign them without wiring up every bit each
/// verb happens to need.
async fn make_admin(store: &Store, user_id: slimm_server::ids::UserId) {
    let role = store
        .create_role("admin", Permissions::ADMINISTRATOR, false)
        .await
        .unwrap();
    store.assign_role(user_id, role).await.unwrap();
}

#[tokio::test]
async fn role_changed_reaches_everyone_without_leaking_bits_or_name() {
    let (store, _guard) = support::new_store("slimm-live-role-events-test").await;
    store
        .create_role("everyone", Permissions::SEND_MESSAGES, true)
        .await
        .unwrap();
    let state = state_for(&store);

    let (alice_access, alice_ticket, alice) = user_ticket(&store, "alice").await;
    let (_bob_access, bob_ticket, _bob) = user_ticket(&store, "bob").await;
    make_admin(&store, alice).await;

    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    let response = http::router(state.clone())
        .oneshot(req(
            "POST",
            "/roles",
            &alice_access,
            Some(json!({ "name": "editors", "permissions": Permissions::ATTACH_FILES.bits() })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let role_id = json_body(response).await["id"].as_str().unwrap().to_owned();

    // Checked on create, update and delete, each its own publish site.
    for ws in [&mut alice_ws, &mut bob_ws] {
        let frame = read_frame(ws).await;
        assert_eq!(frame["type"], "role.changed");
        assert!(frame["role_id"].is_string());
        assert!(
            frame.get("name").is_none() && frame.get("permissions").is_none(),
            "a role's name and bits are gated behind MANAGE_ROLES over REST; \
             the live frame must never carry either: {frame}"
        );
    }

    let update = http::router(state.clone())
        .oneshot(req(
            "PATCH",
            &format!("/roles/{role_id}"),
            &alice_access,
            Some(json!({ "name": "editors-renamed" })),
        ))
        .await
        .unwrap();
    assert_eq!(update.status(), StatusCode::OK);
    for ws in [&mut alice_ws, &mut bob_ws] {
        assert_eq!(read_frame(ws).await["type"], "role.changed");
    }

    let delete = http::router(state.clone())
        .oneshot(req(
            "DELETE",
            &format!("/roles/{role_id}"),
            &alice_access,
            None,
        ))
        .await
        .unwrap();
    assert_eq!(delete.status(), StatusCode::NO_CONTENT);
    for ws in [&mut alice_ws, &mut bob_ws] {
        assert_eq!(read_frame(ws).await["type"], "role.changed");
    }
}

#[tokio::test]
async fn member_role_changed_reaches_everyone() {
    let (store, _guard) = support::new_store("slimm-live-role-events-test").await;
    store
        .create_role("everyone", Permissions::SEND_MESSAGES, true)
        .await
        .unwrap();
    let state = state_for(&store);

    let (alice_access, alice_ticket, alice) = user_ticket(&store, "alice").await;
    let (_bob_access, _bob_ticket, bob) = user_ticket(&store, "bob").await;
    let (_carol_access, carol_ticket, _carol) = user_ticket(&store, "carol").await;
    make_admin(&store, alice).await;
    let perk_role = store
        .create_role("perk", Permissions::ATTACH_FILES, false)
        .await
        .unwrap();

    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    // An uninvolved bystander: entitled anyway since role ids are on `GET /members`.
    let mut carol_ws = connect(addr, &carol_ticket).await;

    let uri = format!("/members/{bob}/roles/{perk_role}");
    let response = http::router(state.clone())
        .oneshot(req("PUT", &uri, &alice_access, None))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    // Checked on both assign and unassign: each is its own publish site.
    for ws in [&mut alice_ws, &mut carol_ws] {
        let frame = read_frame(ws).await;
        assert_eq!(frame["type"], "member.role_changed");
        assert_eq!(frame["user_id"], bob.to_string());
        assert_eq!(frame["role_id"], perk_role.to_string());
    }

    let unassign = http::router(state.clone())
        .oneshot(req("DELETE", &uri, &alice_access, None))
        .await
        .unwrap();
    assert_eq!(unassign.status(), StatusCode::NO_CONTENT);
    for ws in [&mut alice_ws, &mut carol_ws] {
        assert_eq!(read_frame(ws).await["type"], "member.role_changed");
    }
}
