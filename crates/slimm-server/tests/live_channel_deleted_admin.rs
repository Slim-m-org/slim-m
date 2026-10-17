// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `channel.deleted` reaches an admin who sees a private channel only through
//! ADMINISTRATOR. The owner's sidebar kept a deleted private voice channel, so
//! this pins the server side of that as sound.

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

/// Grants ADMINISTRATOR to a user so every test below can create, rename, and
/// delete channels and set or clear overwrites without wiring up every bit
/// each verb happens to need.
async fn make_admin(store: &Store, user_id: slimm_server::ids::UserId) {
    let role = store
        .create_role("admin", Permissions::ADMINISTRATOR, false)
        .await
        .unwrap();
    store.assign_role(user_id, role).await.unwrap();
}

#[tokio::test]
async fn channel_deleted_reaches_an_admin_who_sees_a_private_channel_by_administrator() {
    let (store, _guard) = support::new_store("slimm-live-channel-events-test").await;
    let everyone = store
        .create_role("everyone", Permissions::SEND_MESSAGES, true)
        .await
        .unwrap();
    let _keep = store.create_channel("keep", "text").await.unwrap();
    let doomed = store
        .create_channel("private-voice", "voice")
        .await
        .unwrap();
    store
        .set_role_overwrite(
            doomed.id,
            everyone,
            Permissions::NONE,
            Permissions::VIEW_CHANNEL,
        )
        .await
        .unwrap();
    let state = state_for(&store);

    let (alice_access, alice_ticket, alice) = user_ticket(&store, "alice").await;
    let (_bob_access, bob_ticket, _bob) = user_ticket(&store, "bob").await;
    make_admin(&store, alice).await;

    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    let uri = format!("/channels/{}", doomed.id);
    let response = http::router(state.clone())
        .oneshot(req("DELETE", &uri, &alice_access, None))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    let frame = read_frame(&mut alice_ws).await;
    assert_eq!(frame["type"], "channel.deleted");
    assert_eq!(frame["channel_id"], doomed.id.to_string());

    let bob_next = tokio::time::timeout(Duration::from_millis(300), read_frame(&mut bob_ws)).await;
    assert!(bob_next.is_err(), "bob never saw the private channel");
}
