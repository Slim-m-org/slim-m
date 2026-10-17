// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Live coverage for `Event::ThreadUpdated`: the "thread opened" and "reply
//! added" signal a bystander already viewing the parent channel was missing
//! entirely before this (`docs/decisions/0005-threads.md`'s own writeup
//! named it as deliberately not built).
//!
//! The permission gate itself is not new logic - `ThreadUpdated` is folded
//! into the same channel-scoped check `channel.updated` and `overwrite.changed`
//! already use in `live_channel_events.rs`, keyed on the *parent* channel id -
//! so what needs its own proof here is that the event actually carries that
//! parent id rather than the thread's own, and that a viewer denied on the
//! parent learns nothing about a thread hanging off it.

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
use uuid::Uuid;

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
    let ack = wait_for(&mut ws, "hello", Duration::from_secs(2))
        .await
        .expect("hello ack");
    assert_eq!(ack["type"], "hello");
    ws
}

/// Waits up to `timeout` for a frame whose `type` is `kind`, discarding
/// anything else (a presence ping, or the `message.created` a reply into a
/// thread also produces) - `None` on timeout, never a panic, so this doubles
/// as both the positive and the negative half of a delivery assertion.
async fn wait_for(ws: &mut Client, kind: &str, timeout: Duration) -> Option<Value> {
    tokio::time::timeout(timeout, async {
        loop {
            match ws.next().await {
                Some(Ok(WsMessage::Text(text))) => {
                    let frame: Value = serde_json::from_str(text.as_str()).unwrap();
                    if frame["type"] == kind {
                        return frame;
                    }
                }
                Some(Ok(_)) => continue,
                other => panic!("expected a text frame, got {other:?}"),
            }
        }
    })
    .await
    .ok()
}

async fn read_frame_of_type(ws: &mut Client, kind: &str) -> Value {
    wait_for(ws, kind, Duration::from_secs(2))
        .await
        .unwrap_or_else(|| panic!("timed out waiting for a `{kind}` frame"))
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

/// The bug the task exists to close: today somebody watching a channel where
/// a thread just opened learns nothing until they reload. Carol, denied
/// `VIEW_CHANNEL` on the parent before she even connects, is the control -
/// she must learn nothing either, now or ever.
#[tokio::test]
async fn thread_opened_reaches_a_parent_viewer_and_not_someone_denied_it() {
    let (store, _guard) = support::new_store("slimm-live-thread-events-test").await;
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
    let (_carol_access, carol_ticket, carol) = user_ticket(&store, "carol").await;

    // Denied before carol connects, so the deny itself sends her no frame.
    store
        .set_member_overwrite(
            channel.id,
            carol,
            Permissions::NONE,
            Permissions::VIEW_CHANNEL,
        )
        .await
        .unwrap();

    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;
    let mut carol_ws = connect(addr, &carol_ticket).await;

    let messages_uri = format!("/channels/{}/messages", channel.id);
    let sent = http::router(state.clone())
        .oneshot(req(
            "POST",
            &messages_uri,
            &alice_access,
            Some(json!({ "id": Uuid::now_v7().to_string(), "content": "root" })),
        ))
        .await
        .unwrap();
    assert_eq!(sent.status(), StatusCode::OK);
    let parent_id = json_body(sent).await["id"].as_str().unwrap().to_owned();

    // Drain the `message.created` the send above produced for each viewer.
    read_frame_of_type(&mut alice_ws, "message.created").await;
    read_frame_of_type(&mut bob_ws, "message.created").await;

    let open_uri = format!("{messages_uri}/{parent_id}/thread");
    let opened = http::router(state.clone())
        .oneshot(req("POST", &open_uri, &alice_access, None))
        .await
        .unwrap();
    assert_eq!(opened.status(), StatusCode::OK);
    let thread_id = json_body(opened).await["id"].as_str().unwrap().to_owned();

    let frame = read_frame_of_type(&mut bob_ws, "thread.updated").await;
    assert_eq!(
        frame["channel_id"],
        channel.id.to_string(),
        "the event must carry the parent channel's id, not the thread's own"
    );
    assert_eq!(frame["parent_message_id"], parent_id);
    assert_eq!(frame["thread_channel_id"], thread_id);
    assert_eq!(frame["reply_count"], 0);
    assert!(frame["last_reply_at"].is_null());

    assert!(
        wait_for(&mut carol_ws, "thread.updated", Duration::from_millis(300))
            .await
            .is_none(),
        "carol was denied view of the parent and must not learn a thread opened on it"
    );
}

/// The second half of the gap: once a thread exists, a reply landing in it
/// must move a bystander's reply count live too, not only its opening.
#[tokio::test]
async fn a_reply_in_the_thread_updates_a_parent_viewers_count_live() {
    let (store, _guard) = support::new_store("slimm-live-thread-events-test").await;
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
    let (bob_access, bob_ticket, _bob) = user_ticket(&store, "bob").await;

    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    let messages_uri = format!("/channels/{}/messages", channel.id);
    let sent = http::router(state.clone())
        .oneshot(req(
            "POST",
            &messages_uri,
            &alice_access,
            Some(json!({ "id": Uuid::now_v7().to_string(), "content": "root" })),
        ))
        .await
        .unwrap();
    let parent_id = json_body(sent).await["id"].as_str().unwrap().to_owned();
    read_frame_of_type(&mut alice_ws, "message.created").await;
    read_frame_of_type(&mut bob_ws, "message.created").await;

    let open_uri = format!("{messages_uri}/{parent_id}/thread");
    let opened = http::router(state.clone())
        .oneshot(req("POST", &open_uri, &alice_access, None))
        .await
        .unwrap();
    let thread_id = json_body(opened).await["id"].as_str().unwrap().to_owned();

    // Both already got the "opened" notification; drain it before the reply.
    read_frame_of_type(&mut alice_ws, "thread.updated").await;
    read_frame_of_type(&mut bob_ws, "thread.updated").await;

    let reply_uri = format!("/channels/{thread_id}/messages");
    let reply = http::router(state.clone())
        .oneshot(req(
            "POST",
            &reply_uri,
            &bob_access,
            Some(json!({ "id": Uuid::now_v7().to_string(), "content": "a reply" })),
        ))
        .await
        .unwrap();
    assert_eq!(reply.status(), StatusCode::OK);

    let frame = read_frame_of_type(&mut alice_ws, "thread.updated").await;
    assert_eq!(frame["channel_id"], channel.id.to_string());
    assert_eq!(frame["parent_message_id"], parent_id);
    assert_eq!(frame["thread_channel_id"], thread_id);
    assert_eq!(frame["reply_count"], 1);
    assert!(frame["last_reply_at"].is_i64());
}
