// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The deployment-wide moderation events reach a connected client as frames.
//! `authorize` delivers them to every session with nothing per-viewer to
//! resolve, and cargo-mutants showed no test held it to that: deleting any of
//! the match arms let the event fall through to the channel-scoped path and
//! vanish, with the suite still green. A client that never hears a timeout,
//! removal, restore or join keeps showing the member list as it was.
//!
//! `MemberJoined` is not a moderation event, but it is authorized the same
//! deployment-wide way (see `hub/event.rs`'s own doc comment for why it does
//! not also fire on a restore), so it is covered here rather than starting a
//! third near-identical harness.
//!
//! Its own binary rather than another case in `tests/ws.rs`, which sits at the
//! file-budget ceiling; the connect and read helpers are the same ones.

use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::http::{self, AppState};
use slimm_server::hub::{Event, Hub};
use slimm_server::ids::UserId;
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::Store;
use tokio::net::TcpListener;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message as WsMessage;

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

/// Creates a user and returns (ws connect ticket, user id).
async fn user_ticket(store: &Store, name: &str) -> (String, UserId) {
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

/// The next text frame as JSON, skipping control frames and the
/// `presence.changed` chatter every connect publishes on the shared hub.
async fn read_frame(ws: &mut Client) -> Value {
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
}

async fn next_frame(ws: &mut Client) -> Value {
    tokio::time::timeout(Duration::from_secs(2), read_frame(ws))
        .await
        .expect("the frame must arrive; a dropped moderation event leaves a client stale")
}

#[tokio::test]
async fn a_timeout_a_removal_and_a_restore_each_reach_a_connected_client() {
    let (store, _guard) = support::new_store("slimm-ws-moderation").await;
    let state = state_for(&store);
    let (_alice_ticket, alice) = user_ticket(&store, "alice").await;
    let (bob_ticket, _bob) = user_ticket(&store, "bob").await;
    let addr = serve(state.clone()).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    state.hub.publish(Event::MemberTimeoutChanged {
        user_id: alice,
        until: Some(12_345),
    });
    let frame = next_frame(&mut bob_ws).await;
    assert_eq!(frame["type"], "member.timeout");
    assert_eq!(frame["user_id"], alice.to_string());
    assert_eq!(frame["until"], 12_345);

    state.hub.publish(Event::MemberTimeoutChanged {
        user_id: alice,
        until: None,
    });
    let frame = next_frame(&mut bob_ws).await;
    assert_eq!(frame["type"], "member.timeout");
    assert!(
        frame["until"].is_null(),
        "a lifted timeout is announced as null: {frame}"
    );

    state.hub.publish(Event::MemberRemoved(alice));
    let frame = next_frame(&mut bob_ws).await;
    assert_eq!(frame["type"], "member.removed");
    assert_eq!(frame["user_id"], alice.to_string());

    state.hub.publish(Event::MemberRestored(alice));
    let frame = next_frame(&mut bob_ws).await;
    assert_eq!(frame["type"], "member.restored");
    assert_eq!(frame["user_id"], alice.to_string());

    state.hub.publish(Event::MemberJoined(alice));
    let frame = next_frame(&mut bob_ws).await;
    assert_eq!(frame["type"], "member.joined");
    assert_eq!(frame["user_id"], alice.to_string());
}
