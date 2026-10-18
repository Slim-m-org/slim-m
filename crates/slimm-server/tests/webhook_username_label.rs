// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A webhook post's own `username` label reaching list, sync and the live
//! `message.created` frame, and only on webhook posts.

use axum::http::StatusCode;
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::http::{self};
use slimm_server::ids::{ChannelId, MessageId, UserId};
use slimm_server::store::{NewMessage, Store};
use tokio::net::TcpListener;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message as WsMessage;
use tower::ServiceExt;

mod support;

use support::app::{json_body_or_null as json_body, request};

type Client =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

async fn new_store(name: &str) -> (Store, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new(name);
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool), guard)
}

/// A live administrator, a channel, and the delivery path of a webhook pointed at it.
async fn fixture(store: &Store) -> (String, ChannelId, UserId, String) {
    let account = store
        .create_account("root", "root", "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    let token = store
        .open_session(account.id, "cli")
        .await
        .unwrap()
        .access_token;
    let channel = store.create_channel("general", "text").await.unwrap();
    let minted = store
        .create_webhook(channel.id, "alerts", account.id)
        .await
        .unwrap();
    let path = format!("/webhooks/{}/{}", minted.webhook.id, minted.token);
    (token, channel.id, account.id, path)
}

async fn deliver(app: &axum::Router, path: &str, body: Value) {
    let response = app
        .clone()
        .oneshot(request("POST", path, None, Some(body)))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);
}

fn label_of(messages: &Value, content: &str) -> Value {
    messages
        .as_array()
        .unwrap()
        .iter()
        .find(|m| m["content"] == content)
        .unwrap_or_else(|| panic!("no message {content:?} in {messages}"))["webhook_username"]
        .clone()
}

async fn seed(store: &Store, app: &axum::Router, channel: ChannelId, author: UserId, path: &str) {
    deliver(
        app,
        path,
        json!({ "content": "labelled", "username": "Grafana" }),
    )
    .await;
    deliver(app, path, json!({ "content": "unlabelled" })).await;
    store
        .send_message(NewMessage::plain(
            channel,
            author,
            MessageId::generate(),
            "from a person",
        ))
        .await
        .unwrap();
}

#[tokio::test]
async fn list_carries_the_label_only_on_the_webhook_post_that_set_one() {
    let (store, _guard) = new_store("slimm-webhook-label-list").await;
    let (token, channel, admin, path) = fixture(&store).await;
    let app = http::router(support::app::state(store.clone()));
    seed(&store, &app, channel, admin, &path).await;

    let listed = app
        .clone()
        .oneshot(request(
            "GET",
            &format!("/channels/{channel}/messages"),
            Some(&token),
            None,
        ))
        .await
        .unwrap();
    let messages = json_body(listed).await;

    assert_eq!(label_of(&messages, "labelled"), "Grafana");
    assert!(label_of(&messages, "unlabelled").is_null());
    assert!(label_of(&messages, "from a person").is_null());
}

#[tokio::test]
async fn sync_carries_the_label() {
    let (store, _guard) = new_store("slimm-webhook-label-sync").await;
    let (token, channel, admin, path) = fixture(&store).await;
    let app = http::router(support::app::state(store.clone()));
    seed(&store, &app, channel, admin, &path).await;

    let synced = json_body(
        app.clone()
            .oneshot(request(
                "POST",
                "/sync",
                Some(&token),
                Some(json!({ "scopes": [{ "channel_id": channel.to_string(), "after_seq": 0 }] })),
            ))
            .await
            .unwrap(),
    )
    .await;
    let messages = &synced["scopes"][0]["messages"];

    assert_eq!(label_of(messages, "labelled"), "Grafana");
    assert!(label_of(messages, "unlabelled").is_null());
    assert!(label_of(messages, "from a person").is_null());
}

async fn read_message_created(ws: &mut Client) -> Value {
    loop {
        match ws.next().await {
            Some(Ok(WsMessage::Text(text))) => {
                let frame: Value = serde_json::from_str(text.as_str()).unwrap();
                if frame["type"] == "message.created" {
                    return frame;
                }
            }
            Some(Ok(_)) => continue,
            other => panic!("expected a text frame, got {other:?}"),
        }
    }
}

#[tokio::test]
async fn the_live_frame_carries_the_label() {
    let (store, _guard) = new_store("slimm-webhook-label-ws").await;
    let (token, _channel, _admin, path) = fixture(&store).await;
    let state = support::app::state(store.clone());
    let ctx = store.authenticate(&token).await.unwrap().unwrap();
    let (ticket, _expires_at) = store.mint_ws_ticket(&ctx).await.unwrap();

    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let router = http::router(state.clone());
    tokio::spawn(async move {
        axum::serve(listener, router).await.unwrap();
    });
    let (mut ws, _response) = connect_async(format!("ws://{addr}/ws")).await.unwrap();
    ws.send(WsMessage::Text(
        json!({ "type": "hello", "ticket": ticket, "protocol": 1 }).to_string(),
    ))
    .await
    .unwrap();

    let app = http::router(state);
    deliver(
        &app,
        &path,
        json!({ "content": "labelled", "username": "Grafana" }),
    )
    .await;
    let labelled = read_message_created(&mut ws).await;
    assert_eq!(labelled["message"]["webhook_username"], "Grafana");

    deliver(&app, &path, json!({ "content": "unlabelled" })).await;
    let unlabelled = read_message_created(&mut ws).await;
    assert!(unlabelled["message"]["webhook_username"].is_null());
}
