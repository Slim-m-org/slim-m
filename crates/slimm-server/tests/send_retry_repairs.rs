// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A send whose post-commit writes fail still answers 200, so the client's
//! idempotent retry of the same id must repair what the first attempt
//! missed rather than skip it (issue 2115).

use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use tower::ServiceExt;
use uuid::Uuid;

mod support;
use support::overwrite_harness::{app, json_body, register, request};

#[tokio::test]
async fn a_retry_stores_the_mentions_its_first_attempt_failed_to() {
    let (path, _guard) = support::TestDbGuard::new("slimm-send-retry-repairs");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.unwrap();
    let store = Store::new(pool.clone());
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general-retry", "text").await.unwrap();
    let (alice, _) = register(&store, "alice").await;
    let (bob, _) = register(&store, "bob").await;
    let app = app(store);
    let id = Uuid::now_v7().to_string();
    let send = || {
        request(
            "POST",
            &format!("/channels/{}/messages", channel.id),
            Some(&alice),
            Some(json!({ "id": id, "content": "hey @bob" })),
        )
    };

    sqlx::query(
        "CREATE TRIGGER fail_mentions BEFORE INSERT ON message_mentions
         BEGIN SELECT RAISE(ABORT, 'simulated failure'); END",
    )
    .execute(&pool)
    .await
    .unwrap();
    assert_eq!(
        app.clone().oneshot(send()).await.unwrap().status(),
        StatusCode::OK
    );
    sqlx::query("DROP TRIGGER fail_mentions")
        .execute(&pool)
        .await
        .unwrap();

    assert_eq!(
        app.clone().oneshot(send()).await.unwrap().status(),
        StatusCode::OK
    );

    let listed: Value = json_body(
        app.oneshot(request(
            "GET",
            &format!("/channels/{}/messages", channel.id),
            Some(&bob),
            None,
        ))
        .await
        .unwrap(),
    )
    .await;
    let message = listed
        .as_array()
        .unwrap()
        .iter()
        .find(|m| m["id"] == id)
        .expect("the message is listed");
    assert_eq!(
        message["mentions_me"], true,
        "the retry left bob unmentioned"
    );
}

#[tokio::test]
async fn a_bot_retry_stores_the_buttons_and_embeds_its_first_attempt_failed_to() {
    let (path, _guard) = support::TestDbGuard::new("slimm-send-retry-bot");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.unwrap();
    let store = Store::new(pool.clone());
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general-retry", "text").await.unwrap();
    let (_admin, admin_id) = register(&store, "root").await;
    let bot = store
        .create_bot(
            "helper",
            "Helper",
            Permissions::NONE,
            slimm_server::ids::UserId(admin_id.parse().unwrap()),
        )
        .await
        .unwrap();
    let app = app(store);
    let id = Uuid::now_v7().to_string();
    let send = || {
        request(
            "POST",
            &format!("/channels/{}/messages", channel.id),
            Some(&bot.token),
            Some(json!({
                "id": id,
                "content": "pick one",
                "embeds": [{ "title": "Choices" }],
                "components": [{ "buttons": [{ "label": "Go", "style": "primary", "custom_id": "go" }] }],
            })),
        )
    };

    for table in ["message_components", "message_embeds"] {
        sqlx::query(&format!(
            "CREATE TRIGGER fail_{table} BEFORE INSERT ON {table}
             BEGIN SELECT RAISE(ABORT, 'simulated failure'); END"
        ))
        .execute(&pool)
        .await
        .unwrap();
    }
    let first: Value = json_body(app.clone().oneshot(send()).await.unwrap()).await;
    assert_eq!(
        first["components"],
        json!([]),
        "the simulated failure did not bite"
    );
    for table in ["message_components", "message_embeds"] {
        sqlx::query(&format!("DROP TRIGGER fail_{table}"))
            .execute(&pool)
            .await
            .unwrap();
    }

    let retried: Value = json_body(app.oneshot(send()).await.unwrap()).await;
    assert_eq!(retried["components"][0]["buttons"][0]["custom_id"], "go");
    assert_eq!(retried["embeds"][0]["title"], "Choices");
}
