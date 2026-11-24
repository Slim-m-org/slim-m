// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `POST /channels/{id}/messages` accepting `repost_of_author_id`: bot-only, a real person, read back.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use tower::ServiceExt;
use uuid::Uuid;

use crate::support;
use support::app::{json_body_or_null as json_body, request_json as request};

struct Harness {
    app: Router,
    store: Store,
    channel_id: String,
    _guard: support::TestDbGuard,
}

async fn harness() -> Harness {
    let (path, guard) = support::TestDbGuard::new("slimm-message-repost-author-test");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    let store = Store::new(pool);
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL
                .union(Permissions::SEND_MESSAGES)
                .union(Permissions::MANAGE_SERVER),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let app = support::app::builder(store.clone()).router();
    Harness {
        app,
        store,
        channel_id: channel.id.to_string(),
        _guard: guard,
    }
}

/// A member with a session, and their id.
async fn member(store: &Store, username: &str) -> (String, String) {
    let account = store
        .create_account(username, username, "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    let token = store
        .open_session(account.id, "cli")
        .await
        .unwrap()
        .access_token;
    (token, account.id.to_string())
}

/// A bot, minted by an administrator through the real route.
async fn bot(app: &Router, admin_token: &str, username: &str) -> String {
    let response = app
        .clone()
        .oneshot(request(
            "POST",
            "/bots",
            admin_token,
            json!({ "username": username }),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::CREATED);
    json_body(response).await["token"]
        .as_str()
        .unwrap()
        .to_owned()
}

fn send(channel_id: &str, token: &str, repost_of: &str) -> Request<Body> {
    request(
        "POST",
        &format!("/channels/{channel_id}/messages"),
        token,
        json!({
            "id": Uuid::now_v7().to_string(),
            "content": "starred",
            "repost_of_author_id": repost_of,
        }),
    )
}

#[tokio::test]
async fn a_bots_repost_names_its_author_on_the_send_and_on_the_next_read() {
    let h = harness().await;
    let (admin, _) = member(&h.store, "admin").await;
    let (_, carol) = member(&h.store, "carol").await;
    let bot_token = bot(&h.app, &admin, "starbot").await;

    let sent = h
        .app
        .clone()
        .oneshot(send(&h.channel_id, &bot_token, &carol))
        .await
        .unwrap();
    assert_eq!(sent.status(), StatusCode::OK);
    assert_eq!(json_body(sent).await["repost_of_author_id"], carol);

    let listed = h
        .app
        .clone()
        .oneshot(request(
            "GET",
            &format!("/channels/{}/messages", h.channel_id),
            &admin,
            Value::Null,
        ))
        .await
        .unwrap();
    assert_eq!(listed.status(), StatusCode::OK);
    let body = json_body(listed).await;
    let rows = body.as_array().or(body["messages"].as_array()).unwrap();
    assert_eq!(rows[0]["repost_of_author_id"], carol);
}

/// A person's composer has no such field; discarded rather than refused, as `embeds` are.
#[tokio::test]
async fn a_persons_repost_claim_is_discarded() {
    let h = harness().await;
    let (alice, _) = member(&h.store, "alice").await;
    let (_, carol) = member(&h.store, "carol").await;

    let sent = h
        .app
        .clone()
        .oneshot(send(&h.channel_id, &alice, &carol))
        .await
        .unwrap();
    assert_eq!(sent.status(), StatusCode::OK);
    assert_eq!(json_body(sent).await["repost_of_author_id"], Value::Null);
}

#[tokio::test]
async fn a_bot_naming_no_real_member_is_a_400() {
    let h = harness().await;
    let (admin, _) = member(&h.store, "admin").await;
    let bot_token = bot(&h.app, &admin, "starbot").await;

    for bad in [Uuid::now_v7().to_string(), "not-an-id".to_owned()] {
        let sent = h
            .app
            .clone()
            .oneshot(send(&h.channel_id, &bot_token, &bad))
            .await
            .unwrap();
        assert_eq!(sent.status(), StatusCode::BAD_REQUEST, "{bad}");
    }
}
