// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The temp database, router and request builders every search test is
//! built from.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::store::Store;
use sqlx::SqlitePool;
use tower::ServiceExt;
use uuid::Uuid;

pub async fn new_store() -> (Store, crate::support::TestDbGuard) {
    let (path, guard) = crate::support::TestDbGuard::new("slimm-message-search");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool), guard)
}

/// Like [`new_store`], but keeps a clone of the raw pool too: the
/// `before`/`after` date tests need to plant a `created_at` on a specific
/// calendar day directly, since a message sent through the API always lands
/// on today's date.
pub async fn new_store_with_pool() -> (Store, SqlitePool, crate::support::TestDbGuard) {
    let (path, guard) = crate::support::TestDbGuard::new("slimm-message-search");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool.clone()), pool, guard)
}

pub fn app(store: Store) -> Router {
    crate::support::app::router(store)
}

pub fn request(method: &str, uri: &str, token: Option<&str>, body: Option<Value>) -> Request<Body> {
    let mut builder = Request::builder().method(method).uri(uri);
    if let Some(token) = token {
        builder = builder.header("authorization", format!("Bearer {token}"));
    }
    match body {
        Some(value) => builder
            .header("content-type", "application/json")
            .body(Body::from(value.to_string()))
            .unwrap(),
        None => builder.body(Body::empty()).unwrap(),
    }
}

pub async fn json_body(response: axum::response::Response) -> Value {
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    serde_json::from_slice(&bytes).unwrap()
}

/// A member with a session, built straight through the store.
///
/// Deliberately not the `/auth/register` route: joining a claimed deployment
/// is an invite-gated policy decision, and it is pinned by its own tests in
/// `registration_gate.rs`. These tests only need somebody signed in, so going
/// through the store keeps them independent of that policy.
pub async fn register(store: &Store, username: &str) -> String {
    let account = store
        .create_account(username, username, "not-a-real-hash")
        .await
        .unwrap();
    // The first account through here claims the deployment; later ones find it already set up.
    store.bootstrap_deployment(account.id).await.unwrap();
    store
        .open_session(account.id, "cli")
        .await
        .unwrap()
        .access_token
}

pub async fn send(app: &Router, channel_id: &str, token: &str, content: &str) -> Value {
    json_body(
        app.clone()
            .oneshot(request(
                "POST",
                &format!("/channels/{channel_id}/messages"),
                Some(token),
                Some(json!({ "id": Uuid::now_v7().to_string(), "content": content })),
            ))
            .await
            .unwrap(),
    )
    .await
}

pub async fn send_with_attachments(
    app: &Router,
    channel_id: &str,
    token: &str,
    content: &str,
    attachment_ids: &[&str],
) -> Value {
    json_body(
        app.clone()
            .oneshot(request(
                "POST",
                &format!("/channels/{channel_id}/messages"),
                Some(token),
                Some(json!({
                    "id": Uuid::now_v7().to_string(),
                    "content": content,
                    "attachment_ids": attachment_ids,
                })),
            ))
            .await
            .unwrap(),
    )
    .await
}

/// Uploads a minimal valid PNG (sniffed by its magic bytes, not by a claimed
/// content type) and returns the hex id `sendMessage`'s `attachment_ids`
/// takes.
pub async fn upload_attachment(app: &Router, token: &str) -> String {
    let response = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/attachments")
                .header("authorization", format!("Bearer {token}"))
                .body(Body::from(&b"\x89PNG\r\n\x1a\nrest"[..]))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::CREATED);
    let body = json_body(response).await;
    body["id"].as_str().unwrap().to_owned()
}

/// Plants `created_at` on a message directly, bypassing the API - see
/// [`new_store_with_pool`] for why the date-operator tests need this.
pub async fn set_created_at(pool: &SqlitePool, message_id: &str, created_at_ms: i64) {
    sqlx::query("UPDATE messages SET created_at = ? WHERE id = ?")
        .bind(created_at_ms)
        .bind(Uuid::parse_str(message_id).unwrap())
        .execute(pool)
        .await
        .unwrap();
}
