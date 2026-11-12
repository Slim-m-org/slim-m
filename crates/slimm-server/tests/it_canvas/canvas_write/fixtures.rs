// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Shared setup for the canvas write route's tests: a store, a signed-in
//! caller, and the small POST/GET helpers every test in this module needs.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ids::{ChannelId, UserId};
use slimm_server::store::Store;
use tower::ServiceExt;
use uuid::Uuid;

pub(crate) async fn new_store() -> (Store, crate::support::TestDbGuard) {
    let (store, _pool, guard) = new_store_and_pool().await;
    (store, guard)
}

pub(crate) async fn new_store_and_pool() -> (Store, sqlx::SqlitePool, crate::support::TestDbGuard) {
    let (path, guard) = crate::support::TestDbGuard::new("slimm-canvas-write");
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

pub(crate) async fn register(store: &Store, username: &str) -> (String, UserId) {
    let account = store
        .create_account(username, username, "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    let tokens = store.open_session(account.id, "cli").await.unwrap();
    (tokens.access_token, account.id)
}

pub(crate) const QUERY: &str = "min_x=0&min_y=0&max_x=100&max_y=100&limit=2";

pub(crate) fn region(channel: ChannelId) -> String {
    format!("/channels/{channel}/canvas/objects")
}

pub(crate) async fn general(store: &Store) -> ChannelId {
    store.list_channels().await.unwrap()[0].id
}

pub(crate) async fn post(
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

pub(crate) fn stroke(id: &str) -> Value {
    json!({
        "id": id,
        "kind": "stroke",
        "x": 10.0, "y": 20.0, "w": 30.0, "h": 40.0,
        "props": { "points": [0.0, 0.0, 30.0, 40.0], "width": 3.0, "color": "annotation" },
    })
}

pub(crate) fn id() -> String {
    Uuid::now_v7().to_string()
}

pub(crate) fn chrono_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
}
