// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The temp database, router, deployment and request builders every
//! forwarding test is built from.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::hub::Hub;
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use tower::ServiceExt;
use uuid::Uuid;

pub async fn new_store() -> (Store, crate::support::TestDbGuard) {
    let (store, _pool, guard) = new_store_with_pool().await;
    (store, guard)
}

/// The pool too, for a test that has to backdate a row the API cannot.
pub async fn new_store_with_pool() -> (Store, sqlx::SqlitePool, crate::support::TestDbGuard) {
    let (path, guard) = crate::support::TestDbGuard::new("slimm-message-forwards");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool.clone()), pool, guard)
}

pub fn app_with_hub(store: Store, hub: Hub) -> Router {
    app_with_media(store, hub, slimm_server::media::Media::for_tests())
}

/// The caller keeps a clone of `media` to look at the files on disk.
pub fn app_with_media(store: Store, hub: Hub, media: slimm_server::media::Media) -> Router {
    crate::support::app::builder(store)
        .hub(hub)
        .media(media)
        .router()
}

pub fn app(store: Store) -> Router {
    app_with_hub(store, Hub::new())
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
    serde_json::from_slice(&bytes).unwrap()
}

/// Straight through the store rather than `/auth/register`, which is gated by
/// deployment policy these tests do not exercise; see `message_delete.rs`.
pub async fn register(store: &Store, username: &str, display: &str) -> String {
    let account = store
        .create_account(username, display, "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    store
        .open_session(account.id, "cli")
        .await
        .unwrap()
        .access_token
}

/// A deployment where everyone can see and post, one channel, one member.
pub async fn open_deployment(store: &Store) -> (slimm_server::ids::ChannelId, String) {
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL
                .union(Permissions::SEND_MESSAGES)
                .union(Permissions::MANAGE_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let token = register(store, "alice", "Alice").await;
    (channel.id, token)
}

pub async fn post(
    app: &Router,
    channel: &str,
    token: &str,
    body: Value,
) -> axum::response::Response {
    app.clone()
        .oneshot(request(
            "POST",
            &format!("/channels/{channel}/messages"),
            token,
            Some(body),
        ))
        .await
        .unwrap()
}

pub async fn send(app: &Router, channel: &str, token: &str, content: &str) -> Value {
    let response = post(
        app,
        channel,
        token,
        json!({ "id": Uuid::now_v7().to_string(), "content": content }),
    )
    .await;
    assert_eq!(response.status(), StatusCode::OK);
    json_body(response).await
}

pub fn forward_body(content: &str, origin: &Value) -> Value {
    json!({
        "id": Uuid::now_v7().to_string(),
        "content": content,
        "forwarded_from_id": origin["id"],
    })
}
