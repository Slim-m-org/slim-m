// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The store, router, and request helpers `cases.rs`'s tests share.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ids::{ChannelId, UserId};
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use sqlx::SqlitePool;
use tower::ServiceExt;
use uuid::Uuid;

pub(crate) async fn new_store() -> (Store, SqlitePool, crate::support::TestDbGuard) {
    let (path, guard) = crate::support::TestDbGuard::new("slimm-bulk-delete");
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

pub(crate) async fn bulk_delete(
    app: &Router,
    channel: &str,
    token: &str,
    ids: &[String],
) -> StatusCode {
    app.clone()
        .oneshot(request(
            "POST",
            &format!("/channels/{channel}/messages/bulk-delete"),
            Some(token),
            Some(json!({ "message_ids": ids })),
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
