// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `POST /webhooks/{id}/{token}`: the documented body contract, `allowed_mentions`
//! as a restriction, and a retried delivery repairing a half-written message.

use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ids::{ChannelId, MessageId, UserId};
use slimm_server::store::{NewMessage, Store};
use tower::ServiceExt;
use uuid::Uuid;

use crate::support;
use support::app::{app, json_body_or_null as json_body};

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

async fn member_token(store: &Store, name: &str) -> (String, UserId) {
    let account = store
        .create_account(name, name, "not-a-real-hash")
        .await
        .unwrap();
    let token = store
        .open_session(account.id, "cli")
        .await
        .unwrap()
        .access_token;
    (token, account.id)
}

/// An administrator who owns the channel, plus a second member to mention.
async fn fixture(store: &Store) -> (String, ChannelId, UserId, String, UserId) {
    let (root_token, root) = member_token(store, "root").await;
    store.bootstrap_deployment(root).await.unwrap();
    let (bob_token, bob) = member_token(store, "bob").await;
    let channel = store.create_channel("general", "text").await.unwrap();
    (root_token, channel.id, root, bob_token, bob)
}

fn deliver(path: &str, key: Option<&str>, body: Value) -> Request<Body> {
    let mut request = Request::builder()
        .method("POST")
        .uri(path)
        .header("content-type", "application/json");
    if let Some(key) = key {
        request = request.header("idempotency-key", key);
    }
    request.body(Body::from(body.to_string())).unwrap()
}

fn list_as(token: &str, channel_id: ChannelId) -> Request<Body> {
    Request::builder()
        .method("GET")
        .uri(format!("/channels/{channel_id}/messages"))
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap()
}

async fn mentions_bob(app: &axum::Router, bob_token: &str, channel_id: ChannelId) -> bool {
    let listed = json_body(
        app.clone()
            .oneshot(list_as(bob_token, channel_id))
            .await
            .unwrap(),
    )
    .await;
    listed[0]["mentions_me"].as_bool().unwrap()
}

/// Whether a delivery carrying `body` mentions bob, on a channel of its own.
async fn delivery_mentions_bob(name: &str, body: Value) -> bool {
    let (store, _guard) = new_store(name).await;
    let (_root, channel_id, admin_id, bob_token, _bob) = fixture(&store).await;
    let minted = store
        .create_webhook(channel_id, "alerts", admin_id)
        .await
        .unwrap();
    let app = app(store);
    let path = format!("/webhooks/{}/{}", minted.webhook.id, minted.token);
    let posted = app
        .clone()
        .oneshot(deliver(&path, None, body))
        .await
        .unwrap();
    assert_eq!(posted.status(), StatusCode::NO_CONTENT);
    mentions_bob(&app, &bob_token, channel_id).await
}

#[tokio::test]
async fn an_unrestricted_delivery_mentions_the_named_member() {
    let body = json!({ "content": "paging @bob" });
    assert!(delivery_mentions_bob("slimm-whd-mention-open", body).await);
}

#[tokio::test]
async fn allowed_mentions_with_an_empty_parse_suppresses_mentions() {
    let body = json!({ "content": "paging @bob", "allowed_mentions": { "parse": [] } });
    assert!(!delivery_mentions_bob("slimm-whd-mention-none", body).await);
}

#[tokio::test]
async fn allowed_mentions_can_name_the_users_it_still_allows() {
    let (store, _guard) = new_store("slimm-whd-mention-users").await;
    let (_root, channel_id, admin_id, bob_token, bob) = fixture(&store).await;
    let minted = store
        .create_webhook(channel_id, "alerts", admin_id)
        .await
        .unwrap();
    let app = app(store);
    let path = format!("/webhooks/{}/{}", minted.webhook.id, minted.token);
    let body = json!({
        "content": "paging @bob",
        "allowed_mentions": { "parse": [], "users": [bob.to_string()] },
    });
    let posted = app
        .clone()
        .oneshot(deliver(&path, None, body))
        .await
        .unwrap();
    assert_eq!(posted.status(), StatusCode::NO_CONTENT);
    assert!(mentions_bob(&app, &bob_token, channel_id).await);
}

#[tokio::test]
async fn allowed_mentions_parsing_users_keeps_the_ordinary_mentions() {
    let body = json!({ "content": "paging @bob", "allowed_mentions": { "parse": ["users"] } });
    assert!(delivery_mentions_bob("slimm-whd-mention-parse-users", body).await);
}

#[tokio::test]
async fn an_unreadable_allowed_mentions_never_refuses_the_delivery() {
    for (name, allowed) in [
        ("slimm-whd-mention-null-parse", json!({ "parse": null })),
        ("slimm-whd-mention-numeric-user", json!({ "users": [123] })),
        ("slimm-whd-mention-string", json!("x")),
        ("slimm-whd-mention-null", Value::Null),
    ] {
        let (store, _guard) = new_store(name).await;
        let (_root, channel_id, admin_id, _bob_token, _bob) = fixture(&store).await;
        let minted = store
            .create_webhook(channel_id, "alerts", admin_id)
            .await
            .unwrap();
        let path = format!("/webhooks/{}/{}", minted.webhook.id, minted.token);
        let body = json!({ "content": "paging @bob", "allowed_mentions": allowed });
        let posted = app(store)
            .oneshot(deliver(&path, None, body))
            .await
            .unwrap();
        assert_eq!(posted.status(), StatusCode::NO_CONTENT, "{name}");
    }
}

#[tokio::test]
async fn a_body_less_or_non_json_delivery_answers_the_documented_error() {
    let (store, _guard) = new_store("slimm-whd-body").await;
    let (_root, channel_id, admin_id, _bob_token, _bob) = fixture(&store).await;
    let minted = store
        .create_webhook(channel_id, "alerts", admin_id)
        .await
        .unwrap();
    let app = app(store);
    let path = format!("/webhooks/{}/{}", minted.webhook.id, minted.token);
    let post = |content_type: Option<&str>, body: &'static str| {
        let mut request = Request::builder().method("POST").uri(&path);
        if let Some(content_type) = content_type {
            request = request.header("content-type", content_type);
        }
        request.body(Body::from(body)).unwrap()
    };

    let attempts = [
        post(None, ""),
        post(Some("application/x-www-form-urlencoded"), "content=hi"),
        post(Some("application/json"), ""),
    ];
    for request in attempts {
        let refused = app.clone().oneshot(request).await.unwrap();
        assert_eq!(refused.status(), StatusCode::BAD_REQUEST);
        assert!(json_body(refused).await["error"].is_string());
    }
}

#[test]
fn the_schema_describes_the_body_less_delivery_answer() {
    let schema = std::fs::read_to_string(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../schema/openapi.yaml"
    ))
    .unwrap();
    let operation = schema.split("operationId: deliverWebhook").nth(1).unwrap();
    let body = operation.split("requestBody:").nth(1).unwrap();
    assert!(body.trim_start().starts_with("required: false"));
    assert!(operation.contains("A missing body or any other"));
}

/// A first attempt that committed the message row and died before its embeds and label.
#[tokio::test]
async fn a_retried_delivery_completes_a_message_whose_side_rows_never_landed() {
    let (store, _guard) = new_store("slimm-whd-repair").await;
    let (root_token, channel_id, admin_id, _bob_token, _bob) = fixture(&store).await;
    let minted = store
        .create_webhook(channel_id, "alerts", admin_id)
        .await
        .unwrap();
    let id = MessageId(Uuid::new_v5(&minted.webhook.id.0, b"episode-42"));
    store
        .send_message(NewMessage::plain(
            channel_id,
            minted.webhook.principal_id,
            id,
            "",
        ))
        .await
        .unwrap();
    let app = app(store);

    let path = format!("/webhooks/{}/{}", minted.webhook.id, minted.token);
    let body = json!({ "username": "sonarr", "embeds": [{ "title": "Episode 42" }] });
    for _ in 0..2 {
        let retried = app
            .clone()
            .oneshot(deliver(&path, Some("episode-42"), body.clone()))
            .await
            .unwrap();
        assert_eq!(retried.status(), StatusCode::NO_CONTENT);
    }

    let listed = json_body(app.oneshot(list_as(&root_token, channel_id)).await.unwrap()).await;
    assert_eq!(listed.as_array().unwrap().len(), 1);
    let embeds = listed[0]["embeds"].as_array().unwrap();
    assert_eq!(embeds.len(), 1, "{listed}");
    assert_eq!(embeds[0]["title"], "Episode 42");
    assert_eq!(listed[0]["webhook_username"], "sonarr");
}
