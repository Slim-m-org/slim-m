// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Buttons on a bot's message, the click that reaches only that bot, and the
//! private answer that reaches only the clicker.
//! See docs/decisions/0039-bot-message-buttons.md.

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
use slimm_server::ids::{ChannelId, UserId};
use slimm_server::permissions::Permissions;
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::Store;
use tokio::net::TcpListener;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message as WsMessage;
use tower::ServiceExt;
use uuid::Uuid;

#[path = "../support/mod.rs"]
mod support;

mod answers;
mod bot_ui;
mod call_control_options;
mod presses;
mod security;
mod sending;

type Client =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

struct World {
    state: AppState,
    channel: ChannelId,
    alice: (UserId, String),
    bob: (UserId, String),
    bot: (UserId, String),
    other_bot: (UserId, String),
    db_path: String,
    _guard: support::TestDbGuard,
}

async fn world() -> World {
    let (path, guard) = support::TestDbGuard::new("slimm-buttons");
    let config = Config {
        port: 0,
        database_path: path.clone(),
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    let store = Store::new(pool);
    let root = store
        .create_account("root", "root", "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(root.id).await.unwrap();
    let channel = store.create_channel("general", "text").await.unwrap().id;
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
    let mut bots = Vec::new();
    for name in ["helper", "rival"] {
        let bot = store
            .create_bot(name, name, Permissions::NONE, root.id)
            .await
            .unwrap();
        bots.push((bot.bot.user_id, bot.token));
    }
    let state = AppState {
        store,
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
    };
    World {
        state,
        channel,
        alice: members.remove(0),
        bob: members.remove(0),
        bot: bots.remove(0),
        other_bot: bots.remove(0),
        db_path: path,
        _guard: guard,
    }
}

async fn call(
    w: &World,
    method: &str,
    uri: &str,
    token: &str,
    body: Option<Value>,
) -> (StatusCode, Value) {
    let builder = Request::builder()
        .method(method)
        .uri(uri)
        .header("authorization", format!("Bearer {token}"));
    let request = match body {
        Some(value) => builder
            .header("content-type", "application/json")
            .body(Body::from(value.to_string()))
            .unwrap(),
        None => builder.body(Body::empty()).unwrap(),
    };
    let response = http::router(w.state.clone())
        .oneshot(request)
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

fn buttons() -> Value {
    json!([{ "buttons": [
        { "label": "Hit", "style": "primary", "custom_id": "hit" },
        { "label": "Stand", "style": "secondary", "custom_id": "stand" },
        { "label": "Rules", "style": "link", "url": "https://example.com/rules" }
    ]}])
}

async fn post_with(w: &World, token: &str, components: Value) -> (StatusCode, Value) {
    call(
        w,
        "POST",
        &format!("/channels/{}/messages", w.channel),
        token,
        Some(json!({
            "id": Uuid::now_v7().to_string(),
            "content": "your move",
            "components": components,
        })),
    )
    .await
}

async fn posted(w: &World) -> Value {
    let (status, message) = post_with(w, &w.bot.1, buttons()).await;
    assert_eq!(status, StatusCode::OK);
    message
}

async fn press(
    w: &World,
    token: &str,
    message: &Value,
    custom_id: &str,
) -> (StatusCode, Value, String) {
    let id = Uuid::now_v7().to_string();
    let (status, body) = call(
        w,
        "POST",
        &format!(
            "/channels/{}/messages/{}/interactions",
            w.channel,
            message["id"].as_str().unwrap()
        ),
        token,
        Some(json!({ "id": id, "custom_id": custom_id })),
    )
    .await;
    (status, body, id)
}

async fn whisper(w: &World, token: &str, anchor: &str, text: &str) -> StatusCode {
    call(
        w,
        "POST",
        &format!("/channels/{}/ephemeral-messages", w.channel),
        token,
        Some(json!({ "interaction_id": anchor, "content": text })),
    )
    .await
    .0
}

async fn whisper_to_message(w: &World, token: &str, message_id: &str, text: &str) -> StatusCode {
    call(
        w,
        "POST",
        &format!("/channels/{}/ephemeral-messages", w.channel),
        token,
        Some(json!({ "in_reply_to_id": message_id, "content": text })),
    )
    .await
    .0
}

/// A press whose id the caller picks, to aim it at something that is not a press.
async fn press_as(
    w: &World,
    token: &str,
    message: &Value,
    custom_id: &str,
    id: &str,
) -> StatusCode {
    call(
        w,
        "POST",
        &format!(
            "/channels/{}/messages/{}/interactions",
            w.channel,
            message["id"].as_str().unwrap()
        ),
        token,
        Some(json!({ "id": id, "custom_id": custom_id })),
    )
    .await
    .0
}

async fn connect(w: &World, addr: std::net::SocketAddr, token: &str) -> Client {
    let (_, minted) = call(w, "POST", "/auth/ws-ticket", token, Some(json!({}))).await;
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
