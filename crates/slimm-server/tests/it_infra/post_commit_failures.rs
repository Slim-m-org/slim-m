// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Once a message is stored, a failure in the extras that follow (a webhook's
//! username, mentions) must not hide it: the live event still goes out, so a
//! retry that sees an already-stored id is not the only way anybody learns of it.
#![allow(dead_code)]

use axum::http::StatusCode;
use serde_json::json;
use slimm_server::config::Config;
use slimm_server::hub::{Event, Hub, MessageEvent};
use slimm_server::store::Store;
use sqlx::{Connection, Executor};
use tower::ServiceExt;

use crate::support;
use crate::totp_support;
use totp_support::{app_with_hub, json_body, member, request};

async fn world(
    prefix: &str,
    trigger: &str,
) -> (Store, axum::Router, Hub, String, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new(prefix);
    let config = Config {
        port: 0,
        database_path: path.clone(),
        hash_concurrency: 2,
        ..Config::default()
    };
    let store = Store::new(slimm_server::db::connect(&config).await.unwrap());
    let auth = slimm_server::auth::Auth::new(2).unwrap();
    let (token, _) = member(&store, &auth, "root").await;
    let mut conn = sqlx::SqliteConnection::connect(&format!("sqlite://{path}"))
        .await
        .unwrap();
    conn.execute(trigger).await.unwrap();
    let hub = Hub::new();
    let router = app_with_hub(store.clone(), auth, hub.clone());
    (store, router, hub, token, guard)
}

fn edited_events(rx: &mut tokio::sync::broadcast::Receiver<Event>) -> usize {
    let mut count = 0;
    while let Ok(event) = rx.try_recv() {
        if matches!(event, Event::Message(MessageEvent::Edited { .. })) {
            count += 1;
        }
    }
    count
}

fn created_events(rx: &mut tokio::sync::broadcast::Receiver<Event>) -> usize {
    let mut count = 0;
    while let Ok(event) = rx.try_recv() {
        if matches!(event, Event::Message(MessageEvent::Created { .. })) {
            count += 1;
        }
    }
    count
}

#[tokio::test]
async fn a_webhook_post_whose_username_cannot_be_stored_is_still_announced() {
    let (store, router, hub, token, _guard) = world(
        "slimm-postcommit-webhook",
        "CREATE TRIGGER boom BEFORE INSERT ON webhook_message_usernames \
         BEGIN SELECT RAISE(ABORT, 'boom'); END",
    )
    .await;
    let channel = store.list_channels().await.unwrap()[0].id.to_string();
    let made = router
        .clone()
        .oneshot(request(
            "POST",
            "/webhooks",
            Some(&token),
            Some(json!({"channel_id": channel, "label": "hook"})),
        ))
        .await
        .unwrap();
    let path = json_body(made).await["delivery_path"]
        .as_str()
        .unwrap()
        .to_owned();

    let mut rx = hub.subscribe();
    let response = router
        .oneshot(request(
            "POST",
            &path,
            None,
            Some(json!({"content": "deployed", "username": "Deploys"})),
        ))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::NO_CONTENT);
    assert_eq!(created_events(&mut rx), 1);
}

#[tokio::test]
async fn a_message_whose_mentions_cannot_be_stored_is_still_announced() {
    let (store, router, hub, token, _guard) = world(
        "slimm-postcommit-send",
        "CREATE TRIGGER boom BEFORE INSERT ON message_mentions \
         BEGIN SELECT RAISE(ABORT, 'boom'); END",
    )
    .await;
    let channel = store.list_channels().await.unwrap()[0].id.to_string();

    let mut rx = hub.subscribe();
    let response = router
        .oneshot(request(
            "POST",
            &format!("/channels/{channel}/messages"),
            Some(&token),
            Some(json!({"id": uuid::Uuid::now_v7().to_string(), "content": "hi @everyone @root"})),
        ))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(created_events(&mut rx), 1);
}

const FAIL_MENTIONS: &str = "CREATE TRIGGER boom BEFORE INSERT ON message_mentions \
     BEGIN SELECT RAISE(ABORT, 'boom'); END";

/// A retry of an edit sees unchanged text and publishes nothing, so the first attempt's frame is the only one.
#[tokio::test]
async fn an_edit_whose_mentions_cannot_be_stored_is_still_announced() {
    let (store, router, hub, token, _guard) = world("slimm-postcommit-edit", FAIL_MENTIONS).await;
    store
        .create_account("bob", "bob", "not-a-real-hash")
        .await
        .unwrap();
    let channel = store.list_channels().await.unwrap()[0].id.to_string();
    let id = uuid::Uuid::now_v7().to_string();
    let sent = router
        .clone()
        .oneshot(request(
            "POST",
            &format!("/channels/{channel}/messages"),
            Some(&token),
            Some(json!({"id": id, "content": "hello"})),
        ))
        .await
        .unwrap();
    assert_eq!(sent.status(), StatusCode::OK);

    let mut rx = hub.subscribe();
    let edit = |content: &str| {
        request(
            "PATCH",
            &format!("/channels/{channel}/messages/{id}"),
            Some(&token),
            Some(json!({"content": content})),
        )
    };
    let first = router.clone().oneshot(edit("hello @bob")).await.unwrap();
    let announced = edited_events(&mut rx);
    let retry = router.clone().oneshot(edit("hello @bob")).await.unwrap();

    assert_eq!(
        (
            first.status(),
            announced,
            retry.status(),
            edited_events(&mut rx)
        ),
        (StatusCode::OK, 1, StatusCode::OK, 0),
        "the stored edit answers 200 and is announced exactly once"
    );
}

#[tokio::test]
async fn a_webhook_post_whose_delivery_stamp_cannot_be_written_is_still_delivered() {
    let (store, router, hub, token, _guard) = world(
        "slimm-postcommit-stamp",
        "CREATE TRIGGER boom BEFORE UPDATE ON webhooks \
         BEGIN SELECT RAISE(ABORT, 'boom'); END",
    )
    .await;
    let channel = store.list_channels().await.unwrap()[0].id.to_string();
    let made = router
        .clone()
        .oneshot(request(
            "POST",
            "/webhooks",
            Some(&token),
            Some(json!({"channel_id": channel, "label": "hook"})),
        ))
        .await
        .unwrap();
    let path = json_body(made).await["delivery_path"]
        .as_str()
        .unwrap()
        .to_owned();

    let mut rx = hub.subscribe();
    let response = router
        .oneshot(request(
            "POST",
            &path,
            None,
            Some(json!({"content": "deployed"})),
        ))
        .await
        .unwrap();

    assert_eq!(
        (response.status(), created_events(&mut rx)),
        (StatusCode::NO_CONTENT, 1),
        "a delivery that landed must not answer 500 into a retry that posts it twice"
    );
}
