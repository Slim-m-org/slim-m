// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Shared fixtures for `grants.rs` and `lifecycle.rs`: a running router, an
//! administrator and a plain member with sessions, and a bot creation helper
//! that reports the raw status so a refusal is a value, not a panic.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ids::UserId;
use slimm_server::store::Store;
use sqlx::SqlitePool;
use tower::ServiceExt;

pub async fn harness(name: &str) -> (Store, SqlitePool, crate::support::TestDbGuard) {
    let (path, guard) = crate::support::TestDbGuard::new(name);
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

pub fn request(method: &str, uri: &str, token: &str, body: Option<Value>) -> Request<Body> {
    let builder = Request::builder()
        .method(method)
        .uri(uri)
        .header("authorization", format!("Bearer {token}"));
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
    serde_json::from_slice(&bytes).unwrap_or(Value::Null)
}

/// An administrator with a session, and the deployment claimed by them.
pub async fn admin(store: &Store, username: &str) -> (UserId, String) {
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
    (account.id, token)
}

/// A plain member with a session, holding only `@everyone`.
pub async fn member(store: &Store, username: &str) -> (UserId, String) {
    let account = store.create_user(username, username).await.unwrap();
    let token = store
        .open_session(account.id, "cli")
        .await
        .unwrap()
        .access_token;
    (account.id, token)
}

pub async fn create_bot(
    app: &Router,
    token: &str,
    username: &str,
    permissions: i64,
) -> (String, String, StatusCode) {
    let response = app
        .clone()
        .oneshot(request(
            "POST",
            "/bots",
            token,
            Some(json!({ "username": username, "permissions": permissions })),
        ))
        .await
        .unwrap();
    let status = response.status();
    let body = json_body(response).await;
    if status != StatusCode::CREATED {
        return (String::new(), String::new(), status);
    }
    (
        body["bot"]["user_id"].as_str().unwrap().to_owned(),
        body["token"].as_str().unwrap().to_owned(),
        status,
    )
}
