// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Shared fixtures for the canvas ops test binary: a store, a router, an
//! authenticated caller, and the HTTP helpers both sibling modules need.
//!
//! Bulk fixtures go through `Store` directly rather than HTTP, the same
//! choice `canvas_write.rs`'s ceiling test makes, so a fixture that places or
//! seeds dozens of rows is not also a rate-limit test in disguise.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ids::{CanvasObjectId, CanvasOpId, ChannelId, UserId};
use slimm_server::store::{PlaceRequest, Store};
use tower::ServiceExt;
use uuid::Uuid;

pub(crate) async fn new_store_and_pool() -> (Store, sqlx::SqlitePool, crate::support::TestDbGuard) {
    let (path, guard) = crate::support::TestDbGuard::new("slimm-canvas-ops");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool.clone()), pool, guard)
}

pub(crate) async fn new_store() -> (Store, crate::support::TestDbGuard) {
    let (store, _pool, guard) = new_store_and_pool().await;
    (store, guard)
}

pub(crate) fn app(store: Store) -> Router {
    crate::support::app::router(store)
}

pub(crate) async fn register(store: &Store, username: &str) -> (String, UserId) {
    let account = store
        .create_account(username, username, "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    let tokens = store.open_session(account.id, "cli").await.unwrap();
    (tokens.access_token, account.id)
}

/// An ordinary member, distinct from the deployment-claiming administrator
/// [`register`] creates: only `@everyone`'s bits, so `MANAGE_CANVAS` is
/// absent unless a test grants it.
pub(crate) async fn member(store: &Store, username: &str) -> (String, UserId) {
    let account = store
        .create_account(username, username, "not-a-real-hash")
        .await
        .unwrap();
    let tokens = store.open_session(account.id, "cli").await.unwrap();
    (tokens.access_token, account.id)
}

pub(crate) async fn general(store: &Store) -> ChannelId {
    store.list_channels().await.unwrap()[0].id
}

pub(crate) fn stroke(id: &str) -> Value {
    json!({
        "id": id, "kind": "stroke",
        "x": 10.0, "y": 20.0, "w": 30.0, "h": 40.0,
        "props": { "points": [0.0, 0.0, 30.0, 40.0], "width": 3.0, "color": "annotation" },
    })
}

pub(crate) fn id() -> String {
    Uuid::now_v7().to_string()
}

pub(crate) async fn post_object(
    app: &Router,
    channel: ChannelId,
    token: &str,
    body: Value,
) -> (StatusCode, Value) {
    let response = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/channels/{channel}/canvas/objects"))
                .header("authorization", format!("Bearer {token}"))
                .header("content-type", "application/json")
                .body(Body::from(serde_json::to_vec(&body).unwrap()))
                .unwrap(),
        )
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

pub(crate) async fn submit_op(
    app: &Router,
    channel: ChannelId,
    token: &str,
    body: Value,
) -> (StatusCode, Value) {
    let response = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/channels/{channel}/canvas/ops"))
                .header("authorization", format!("Bearer {token}"))
                .header("content-type", "application/json")
                .body(Body::from(serde_json::to_vec(&body).unwrap()))
                .unwrap(),
        )
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

pub(crate) fn remove(id: &str, object_ids: &[&str]) -> Value {
    json!({ "id": id, "kind": "remove", "object_ids": object_ids })
}

pub(crate) fn clear(id: &str, before_seq: i64) -> Value {
    json!({ "id": id, "kind": "clear", "before_seq": before_seq })
}

pub(crate) fn restore(id: &str, target_op: &str) -> Value {
    json!({ "id": id, "kind": "restore", "target_op": target_op })
}

pub(crate) fn move_op(id: &str, object_id: &str, bounds: (f64, f64, f64, f64)) -> Value {
    let (x, y, w, h) = bounds;
    json!({ "id": id, "kind": "move", "object_id": object_id, "x": x, "y": y, "w": w, "h": h })
}

pub(crate) fn note(id: &str, text: &str) -> Value {
    json!({
        "id": id, "kind": "note",
        "x": 10.0, "y": 20.0, "w": 220.0, "h": 140.0,
        "props": { "text": text, "color": "annotation" },
    })
}

pub(crate) fn edit_op(id: &str, object_id: &str, props: Value) -> Value {
    json!({ "id": id, "kind": "edit", "object_id": object_id, "props": props })
}

pub(crate) fn reorder_op(id: &str, object_id: &str, z_index: i64) -> Value {
    json!({ "id": id, "kind": "reorder", "object_id": object_id, "z_index": z_index })
}

pub(crate) async fn get_ops(
    app: &Router,
    channel: ChannelId,
    token: &str,
    query: &str,
) -> (StatusCode, Value) {
    let response = app
        .clone()
        .oneshot(
            Request::builder()
                .method("GET")
                .uri(format!("/channels/{channel}/canvas/ops?{query}"))
                .header("authorization", format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
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

/// Seeds `count` placed objects in one transaction: the same rows `place`
/// writes per call - a `canvas_objects` row and its `canvas_ops` place row
/// under a shared canvas seq, plus a single counter bump - but without a
/// transaction per object, which is the difference between a budget test that
/// needs tens of thousands of objects finishing in a second and in a minute.
/// The R-Tree stays in sync through its own `AFTER INSERT` trigger, exactly as
/// a real place relies on; `channel_key` is inlined from its `pub(crate)`
/// formula since a test binary cannot reach it. A caller's own `affected` and
/// feed assertions are what prove this reproduced the real placed state.
pub(crate) async fn place_many(
    pool: &sqlx::SqlitePool,
    channel: ChannelId,
    author: UserId,
    count: i64,
) {
    let bytes = channel.0.as_bytes();
    let key = (i64::from(bytes[13]) << 16) | (i64::from(bytes[14]) << 8) | i64::from(bytes[15]);
    let mut tx = pool.begin().await.unwrap();
    let next: i64 = sqlx::query_scalar(
        "UPDATE channel_seq_counters SET next_seq = next_seq + ? \
         WHERE channel_id = ? AND stream = 'canvas' RETURNING next_seq",
    )
    .bind(count)
    .bind(channel)
    .fetch_one(&mut *tx)
    .await
    .unwrap();
    let base = next - count;
    for i in 0..count {
        let seq = base + i;
        sqlx::query(
            "INSERT INTO canvas_objects \
             (id, channel_id, channel_key, kind, z_index, x, y, w, h, props, author_id, seq, created_at) \
             VALUES (?, ?, ?, 'stroke', ?, 0.0, 0.0, 1.0, 1.0, '{}', ?, ?, 0)",
        )
        .bind(CanvasObjectId::generate())
        .bind(channel)
        .bind(key)
        .bind(seq)
        .bind(author)
        .bind(seq)
        .execute(&mut *tx)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO canvas_ops (channel_id, seq, id, kind, actor_id, created_at) \
             VALUES (?, ?, ?, 'place', ?, 0)",
        )
        .bind(channel)
        .bind(seq)
        .bind(CanvasOpId::generate())
        .bind(author)
        .execute(&mut *tx)
        .await
        .unwrap();
    }
    tx.commit().await.unwrap();
}

/// Places one object directly through the store, bypassing the HTTP rate limiter.
pub(crate) async fn place(
    store: &Store,
    channel: ChannelId,
    author: UserId,
    props_bytes: usize,
) -> CanvasObjectId {
    let id = CanvasObjectId::generate();
    let props = if props_bytes == 0 {
        "{}".to_owned()
    } else {
        serde_json::to_string(&json!({ "filler": "x".repeat(props_bytes) })).unwrap()
    };
    store
        .place_canvas_object(
            channel,
            author,
            id,
            PlaceRequest {
                kind: "stroke",
                bounds: (0.0, 0.0, 1.0, 1.0),
                props: &props,
                attachment: None,
            },
        )
        .await
        .expect("placed");
    id
}
