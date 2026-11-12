// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The store, router, and request helpers `cases.rs`'s tests share.
//!
//! Duplicated from `message_bulk_delete/harness.rs` rather than imported: an
//! integration test is its own crate, so two test binaries cannot share a
//! module, the same reason that file's own doc names for
//! `canvas_ops/index_plan.rs`'s technique.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ids::{ChannelId, MessageId, UserId};
use slimm_server::permissions::Permissions;
use slimm_server::store::{NewMessage, Store};
use sqlx::SqlitePool;
use tower::ServiceExt;
use uuid::Uuid;

pub(crate) async fn new_store() -> (Store, SqlitePool, crate::support::TestDbGuard) {
    let (path, guard) = crate::support::TestDbGuard::new("slimm-bulk-delete-window");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool.clone()), pool, guard)
}

pub(crate) fn app(store: Store) -> Router {
    crate::support::app::router(store)
}

pub(crate) fn request(
    method: &str,
    uri: &str,
    token: Option<&str>,
    body: Option<Value>,
) -> Request<Body> {
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

pub(crate) async fn json_body(response: axum::response::Response) -> Value {
    let bytes = axum::body::to_bytes(response.into_body(), 1 << 20)
        .await
        .unwrap();
    serde_json::from_slice(&bytes).unwrap_or(Value::Null)
}

pub(crate) async fn account(store: &Store, username: &str) -> (String, UserId) {
    let user = store
        .create_account(username, username, "not-a-real-hash")
        .await
        .unwrap();
    let tokens = store.open_session(user.id, "cli").await.unwrap();
    (tokens.access_token, user.id)
}

/// An administrator who owns the deployment, a moderator holding only
/// MANAGE_MESSAGES, and an ordinary member to be moderated.
pub(crate) async fn people(
    store: &Store,
) -> ((String, UserId), (String, UserId), (String, UserId)) {
    let admin = account(store, "root").await;
    store.bootstrap_deployment(admin.1).await.unwrap();
    let moderator = account(store, "mod").await;
    let member = account(store, "nia").await;
    let role = store
        .create_role("mods", Permissions::MANAGE_MESSAGES, false)
        .await
        .unwrap();
    store.assign_role(moderator.1, role).await.unwrap();
    (admin, moderator, member)
}

pub(crate) async fn channel_id(store: &Store) -> String {
    store.list_channels().await.unwrap()[0].id.0.to_string()
}

pub(crate) async fn send(app: &Router, channel: &str, token: &str, content: &str) -> String {
    let body = json_body(
        app.clone()
            .oneshot(request(
                "POST",
                &format!("/channels/{channel}/messages"),
                Some(token),
                Some(json!({ "id": Uuid::now_v7().to_string(), "content": content })),
            ))
            .await
            .unwrap(),
    )
    .await;
    body["id"].as_str().unwrap().to_owned()
}

/// Sends [count] messages straight through the store, bypassing the HTTP
/// `Class::Write` rate limit entirely: `exactly_the_cap_succeeds` and its
/// over-the-cap sibling need more sends from one author than the 30-request
/// burst allows, and what is under test is the selection query, not the send
/// path itself.
pub(crate) async fn send_many(store: &Store, channel: &str, author_id: UserId, count: usize) {
    let id = ChannelId(Uuid::parse_str(channel).unwrap());
    for i in 0..count {
        store
            .send_message(NewMessage::plain(
                id,
                author_id,
                MessageId(Uuid::now_v7()),
                &format!("spam {i}"),
            ))
            .await
            .unwrap();
    }
}

pub(crate) async fn bulk_delete_by_author(
    app: &Router,
    channel: &str,
    token: &str,
    author_id: &str,
    window_minutes: u32,
) -> StatusCode {
    app.clone()
        .oneshot(request(
            "POST",
            &format!("/channels/{channel}/messages/bulk-delete-by-author"),
            Some(token),
            Some(json!({ "author_id": author_id, "window_minutes": window_minutes })),
        ))
        .await
        .unwrap()
        .status()
}

pub(crate) async fn live_count(store: &Store, channel: &str) -> usize {
    let id = ChannelId(Uuid::parse_str(channel).unwrap());
    store.list_messages(id, None, 100).await.unwrap().len()
}

/// Every delete op this channel has, oldest first, as `(seq, kind)`.
pub(crate) async fn ops(pool: &SqlitePool, channel: &str) -> Vec<(i64, String)> {
    let id = ChannelId(Uuid::parse_str(channel).unwrap());
    sqlx::query_as("SELECT seq, kind FROM message_ops WHERE channel_id = ? ORDER BY seq")
        .bind(id)
        .fetch_all(pool)
        .await
        .expect("read the op stream")
}

pub(crate) async fn audit(pool: &SqlitePool) -> Vec<(String, Option<Vec<u8>>, Option<Vec<u8>>)> {
    sqlx::query_as("SELECT action, actor_id, subject_id FROM moderation_audit_log ORDER BY id")
        .fetch_all(pool)
        .await
        .expect("read the audit log")
}

/// Backdates a message's `created_at` so a window test can put it outside the
/// window without waiting real wall-clock time for it to age out.
pub(crate) async fn backdate(pool: &SqlitePool, message_id: &str, created_at_ms: i64) {
    sqlx::query("UPDATE messages SET created_at = ? WHERE id = ?")
        .bind(created_at_ms)
        .bind(Uuid::parse_str(message_id).unwrap())
        .execute(pool)
        .await
        .expect("backdate the message");
}

pub(crate) fn now_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}
