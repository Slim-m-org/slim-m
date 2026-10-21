// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A read marker that does not move must not broadcast: the frame wakes every
//! socket on the shared durable channel, and only one account can use it.

use std::time::Duration;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::http::{self, AppState};
use slimm_server::hub::Event;
use slimm_server::ids::{ChannelId, MessageId, UserId};
use slimm_server::permissions::Permissions;
use slimm_server::store::{NewMessage, Store};
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message as WsMessage;
use tower::ServiceExt;
use uuid::Uuid;

mod support;

use support::ws::{Client, serve};

struct Fixture {
    state: AppState,
    channel: ChannelId,
    user: UserId,
    bob: UserId,
    token: String,
    ticket: String,
    _guard: support::TestDbGuard,
}

async fn setup() -> Fixture {
    let (path, guard) = support::TestDbGuard::new("slimm-read-marker-noop");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let store = Store::new(db::connect(&config).await.expect("connect + migrate"));
    let everyone = Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES);
    store.create_role("everyone", everyone, true).await.unwrap();
    let channel = store.create_channel("general", "text").await.unwrap().id;
    let user = store.create_user("alice", "Alice").await.unwrap().id;
    let bob = store.create_user("bob", "Bob").await.unwrap().id;
    let tokens = store.open_session(user, "device").await.unwrap();
    let ctx = store
        .authenticate(&tokens.access_token)
        .await
        .unwrap()
        .unwrap();
    let (ticket, _) = store.mint_ws_ticket(&ctx).await.unwrap();
    let state = support::app::state(store);
    Fixture {
        state,
        channel,
        user,
        bob,
        token: tokens.access_token,
        ticket,
        _guard: guard,
    }
}

impl Fixture {
    async fn call(&self, method: &str, uri: &str, body: Value) -> StatusCode {
        let request = Request::builder()
            .method(method)
            .uri(uri)
            .header("authorization", format!("Bearer {}", self.token))
            .header("content-type", "application/json")
            .body(Body::from(body.to_string()))
            .unwrap();
        let response = http::router(self.state.clone()).oneshot(request).await;
        response.unwrap().status()
    }

    async fn put_read(&self, seq: i64) {
        let uri = format!("/channels/{}/read", self.channel);
        assert_eq!(
            self.call("PUT", &uri, json!({ "seq": seq })).await,
            StatusCode::OK
        );
    }

    async fn put_unread(&self) {
        let uri = format!("/channels/{}/unread", self.channel);
        assert_eq!(self.call("PUT", &uri, json!({})).await, StatusCode::OK);
    }

    async fn message_from_someone_else(&self) {
        let message = NewMessage::plain(self.channel, self.bob, MessageId::generate(), "hi");
        self.state.store.send_message(message).await.unwrap();
    }

    async fn post_message(&self) {
        let uri = format!("/channels/{}/messages", self.channel);
        let body = json!({ "id": Uuid::now_v7().to_string(), "content": "hi" });
        assert_eq!(self.call("POST", &uri, body).await, StatusCode::OK);
    }
}

async fn connect(addr: std::net::SocketAddr, ticket: &str) -> Client {
    let (mut ws, _) = connect_async(format!("ws://{addr}/ws")).await.unwrap();
    let hello = json!({ "type": "hello", "ticket": ticket, "protocol": 1 });
    ws.send(WsMessage::Text(hello.to_string())).await.unwrap();
    assert_eq!(
        next_frame(&mut ws, Duration::from_secs(5)).await.unwrap()["type"],
        "hello"
    );
    ws
}

async fn next_frame(ws: &mut Client, within: Duration) -> Option<Value> {
    let read = async {
        loop {
            match ws.next().await {
                Some(Ok(WsMessage::Text(text))) => {
                    let frame: Value = serde_json::from_str(text.as_str()).unwrap();
                    if frame["type"] != "presence.changed" {
                        return frame;
                    }
                }
                Some(Ok(_)) => continue,
                other => panic!("expected a text frame, got {other:?}"),
            }
        }
    };
    tokio::time::timeout(within, read).await.ok()
}

/// The `read_state.changed` frames that arrive before the socket goes quiet.
async fn read_frames(ws: &mut Client) -> Vec<Value> {
    let mut frames = Vec::new();
    while let Some(frame) = next_frame(ws, Duration::from_millis(400)).await {
        if frame["type"] == "read_state.changed" {
            frames.push(frame);
        }
    }
    frames
}

#[tokio::test]
async fn an_identical_second_mark_sends_no_frame_to_the_other_device() {
    let f = setup().await;
    f.message_from_someone_else().await;
    let mut other = connect(serve(f.state.clone()).await, &f.ticket).await;
    read_frames(&mut other).await;

    f.put_read(1).await;
    let first = read_frames(&mut other).await;
    assert_eq!(first.len(), 1, "the first mark moved the marker");
    assert_eq!(first[0]["last_read_seq"], 1);

    f.put_read(1).await;
    f.put_read(0).await;
    let repeats = read_frames(&mut other).await;
    assert!(
        repeats.is_empty(),
        "a no-op mark must be silent: {repeats:?}"
    );
}

#[tokio::test]
async fn clearing_a_manual_unread_announces_even_when_the_seq_stays() {
    let f = setup().await;
    f.message_from_someone_else().await;
    f.put_read(1).await;
    f.put_unread().await;
    let mut other = connect(serve(f.state.clone()).await, &f.ticket).await;
    read_frames(&mut other).await;

    f.put_read(1).await;
    let frames = read_frames(&mut other).await;
    assert_eq!(frames.len(), 1, "clearing the flag is a change: {frames:?}");
    assert_eq!(frames[0]["last_read_seq"], 1);
    assert!(
        !f.state
            .store
            .manually_unread(f.user, f.channel)
            .await
            .unwrap()
    );
}

#[tokio::test]
async fn the_authors_own_message_still_advances_and_announces() {
    let f = setup().await;
    let mut other = connect(serve(f.state.clone()).await, &f.ticket).await;
    read_frames(&mut other).await;

    f.post_message().await;
    let frames = read_frames(&mut other).await;
    assert_eq!(frames.len(), 1, "the author's marker moves with the send");
    assert_eq!(frames[0]["last_read_seq"], 1);
    assert_eq!(
        f.state
            .store
            .last_read_seq(f.user, f.channel)
            .await
            .unwrap(),
        1
    );
}

#[tokio::test]
async fn twenty_identical_marks_publish_one_event() {
    let f = setup().await;
    for _ in 0..20 {
        f.message_from_someone_else().await;
    }
    let mut bystander = f.state.hub.subscribe();
    while bystander.try_recv().is_ok() {}

    for _ in 0..20 {
        f.put_read(20).await;
    }
    let mut changed = 0;
    while let Ok(event) = bystander.try_recv() {
        if matches!(event, Event::ReadStateChanged { .. }) {
            changed += 1;
        }
    }
    assert_eq!(changed, 1);
}
