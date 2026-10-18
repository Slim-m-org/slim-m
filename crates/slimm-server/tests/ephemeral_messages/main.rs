// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `POST /channels/{id}/ephemeral-messages`: a bot's private answer reaches
//! exactly one member's sockets and leaves no trace anywhere else.
//! See docs/decisions/0037-ephemeral-bot-messages.md.

use std::time::Duration;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::http::{self, AppState};
use slimm_server::ids::{ChannelId, UserId};
use slimm_server::permissions::Permissions;
use slimm_server::store::{BotCommand, Store};
use tokio::net::TcpListener;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message as WsMessage;
use tower::ServiceExt;
use uuid::Uuid;

#[path = "../support/mod.rs"]
mod support;

mod reports;
mod rich;
mod sending;

type Client =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

struct World {
    state: AppState,
    pool: sqlx::SqlitePool,
    channel: ChannelId,
    admin: (UserId, String),
    alice: (UserId, String),
    bob: (UserId, String),
    bot: (UserId, String),
    _guard: support::TestDbGuard,
}

async fn world() -> World {
    let (path, guard) = support::TestDbGuard::new("slimm-ephemeral");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    let store = Store::new(pool.clone());
    let root = store
        .create_account("root", "root", "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(root.id).await.unwrap();
    let channel = store.create_channel("general", "text").await.unwrap().id;
    let admin_token = store
        .open_session(root.id, "cli")
        .await
        .unwrap()
        .access_token;
    let mut members = Vec::new();
    for name in ["alice", "bob"] {
        let user = store.create_user(name, name).await.unwrap();
        let token = store
            .open_session(user.id, "cli")
            .await
            .unwrap()
            .access_token;
        members.push((user.id, token));
    }
    let bot = store
        .create_bot("helper", "Helper", Permissions::NONE, root.id)
        .await
        .unwrap();
    store
        .set_bot_commands(
            bot.bot.user_id,
            "!",
            &[BotCommand {
                name: "balance".to_owned(),
                description: "show a balance".to_owned(),
                usage: None,
                permission: None,
            }],
        )
        .await
        .unwrap();
    let state = crate::support::app::state(store);
    World {
        state,
        pool,
        channel,
        admin: (root.id, admin_token),
        alice: members.remove(0),
        bob: members.remove(0),
        bot: (bot.bot.user_id, bot.token),
        _guard: guard,
    }
}

fn request(method: &str, uri: &str, token: &str, body: Option<Value>) -> Request<Body> {
    let builder = Request::builder()
        .method(method)
        .uri(uri)
        .header("authorization", format!("Bearer {token}"));
    match body {
        Some(value) => builder
            .header("content-type", "application/json")
            .body(Body::from(value.to_string()))
            .unwrap(),
        None => builder.body(Body::empty()).unwrap(),
    }
}

async fn call(
    w: &World,
    method: &str,
    uri: &str,
    token: &str,
    body: Option<Value>,
) -> (StatusCode, Value) {
    let response = http::router(w.state.clone())
        .oneshot(request(method, uri, token, body))
        .await
        .unwrap();
    let status = response.status();
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    (
        status,
        serde_json::from_slice(&bytes).unwrap_or(Value::Null),
    )
}

async fn say(w: &World, token: &str, channel: ChannelId, text: &str) -> Value {
    let (status, body) = call(
        w,
        "POST",
        &format!("/channels/{channel}/messages"),
        token,
        Some(json!({ "id": Uuid::now_v7().to_string(), "content": text })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    body
}

async fn whisper(
    w: &World,
    token: &str,
    channel: ChannelId,
    anchor: &Value,
    text: &str,
) -> (StatusCode, Value) {
    call(
        w,
        "POST",
        &format!("/channels/{channel}/ephemeral-messages"),
        token,
        Some(json!({ "in_reply_to_id": anchor["id"], "content": text })),
    )
    .await
}

async fn connect(w: &World, addr: std::net::SocketAddr, token: &str) -> Client {
    let (status, minted) = call(w, "POST", "/auth/ws-ticket", token, Some(json!({}))).await;
    assert_eq!(status, StatusCode::OK);
    let ticket = minted["ticket"].as_str().unwrap().to_owned();
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
                let frame: Value = serde_json::from_str(text.as_str()).unwrap();
                if frame["type"] != "presence.changed" {
                    return frame;
                }
            }
            Some(Ok(_)) => continue,
            other => panic!("expected a text frame, got {other:?}"),
        }
    }
}

async fn frame_of_kind(ws: &mut Client, kind: &str) -> Option<Value> {
    while let Ok(frame) = tokio::time::timeout(Duration::from_millis(400), read_frame(ws)).await {
        if frame["type"] == kind {
            return Some(frame);
        }
    }
    None
}

async fn serve(state: AppState) -> std::net::SocketAddr {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(listener, http::router(state)).await.unwrap();
    });
    addr
}
