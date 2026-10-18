// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! One set of embed caps: the webhook and bot send routes must refuse the
//! same one-over-the-limit payload identically.

use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::store::Store;
use tower::ServiceExt;
use uuid::Uuid;

mod support;

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

fn eleven_embeds() -> Vec<Value> {
    (0..11)
        .map(|_| json!({ "title": "one embed too many" }))
        .collect()
}

/// The one-over-the-limit payload the webhook route refuses, standalone.
#[tokio::test]
async fn a_webhook_refuses_eleven_embeds() {
    let (store, _guard) = new_store("slimm-embed-caps-shared-webhook").await;
    let account = store
        .create_account("root", "root", "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let minted = store
        .create_webhook(channel.id, "alerts", account.id)
        .await
        .unwrap();
    let app = app(store);

    let response = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/webhooks/{}/{}", minted.webhook.id, minted.token))
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({ "content": "spam", "embeds": eleven_embeds() }).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

/// The bot send route rejects the same payload the webhook route above does.
#[tokio::test]
async fn bot_and_webhook_refuse_the_identical_one_over_limit_payload() {
    let (store, _guard) = new_store("slimm-embed-caps-shared-bot").await;
    store
        .create_role(
            "everyone",
            slimm_server::permissions::Permissions::VIEW_CHANNEL
                .union(slimm_server::permissions::Permissions::SEND_MESSAGES)
                .union(slimm_server::permissions::Permissions::MANAGE_SERVER),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let account = store
        .create_account("admin", "admin", "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    let admin_token = store
        .open_session(account.id, "cli")
        .await
        .unwrap()
        .access_token;
    let app = app(store.clone());

    let create_bot = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/bots")
                .header("authorization", format!("Bearer {admin_token}"))
                .header("content-type", "application/json")
                .body(Body::from(json!({ "username": "ci-bot" }).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(create_bot.status(), StatusCode::CREATED);
    let bot_token = json_body(create_bot).await["token"]
        .as_str()
        .unwrap()
        .to_owned();

    let sent = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/channels/{}/messages", channel.id))
                .header("authorization", format!("Bearer {bot_token}"))
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "id": Uuid::now_v7().to_string(),
                        "content": "spam",
                        "embeds": eleven_embeds(),
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(
        sent.status(),
        StatusCode::BAD_REQUEST,
        "the bot send route must refuse the same 11-embed payload the webhook route refuses"
    );
}
