// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The temp database, temp media root, router and request builders the
//! attachment tests are built from.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::Value;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ids::UserId;
use slimm_server::media::Media;
use slimm_server::store::Store;
use tower::ServiceExt;

/// Small enough that the over-size test does not need to allocate real
/// megabytes to exceed it.
pub const TEST_MAX_ATTACHMENT_BYTES: u64 = 4096;

pub async fn new_store() -> (Store, crate::support::TestDbGuard) {
    let (store, _pool, guard) = new_store_and_pool().await;
    (store, guard)
}

/// [`new_store`] that also hands back the pool, for tests that need raw SQL.
pub async fn new_store_and_pool() -> (Store, sqlx::SqlitePool, crate::support::TestDbGuard) {
    let (path, guard) = crate::support::TestDbGuard::new("slimm-attachments-test");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool.clone()), pool, guard)
}

pub fn media_for_test() -> Media {
    Media::for_tests().with_attachment_max(TEST_MAX_ATTACHMENT_BYTES)
}

/// An extractor whose PDF child is the built server binary, never the test harness.
pub fn extractor(retry_backoff: std::time::Duration) -> slimm_server::TextExtractor {
    let worker = slimm_server::PdfWorker::command(
        env!("CARGO_BIN_EXE_slimm-server").into(),
        vec![slimm_server::PDF_WORKER_ARG.into()],
        std::time::Duration::from_secs(20),
    );
    slimm_server::TextExtractor::with_worker(Some(worker), retry_backoff)
}

pub fn app(store: Store) -> Router {
    app_with_media(store, media_for_test())
}

pub fn app_with_media(store: Store, media: Media) -> Router {
    crate::support::app::builder(store).media(media).router()
}

pub fn request_json(method: &str, uri: &str, token: &str, body: Value) -> Request<Body> {
    Request::builder()
        .method(method)
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .header("content-type", "application/json")
        .body(Body::from(body.to_string()))
        .unwrap()
}

pub fn request_bytes(method: &str, uri: &str, token: &str, body: Vec<u8>) -> Request<Body> {
    Request::builder()
        .method(method)
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .body(Body::from(body))
        .unwrap()
}

pub fn request_plain(method: &str, uri: &str, token: &str) -> Request<Body> {
    Request::builder()
        .method(method)
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap()
}

pub async fn json_body(response: axum::response::Response) -> Value {
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    serde_json::from_slice(&bytes).unwrap()
}

/// A member with a session, built straight through the store (see
/// `message_endpoints.rs` for why: joining a claimed deployment is an
/// invite-gated policy pinned by its own tests, and these do not need it).
pub async fn register(store: &Store, username: &str) -> (String, UserId) {
    let account = store
        .create_account(username, username, "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    let tokens = store.open_session(account.id, "cli").await.unwrap();
    (tokens.access_token, account.id)
}

/// A minimal, validly-sniffable PNG: only the 8-byte magic number matters to
/// the allowlist, so the rest is arbitrary padding to reach a given size.
pub fn png(padding: usize) -> Vec<u8> {
    let mut bytes = vec![0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
    bytes.extend(std::iter::repeat_n(0u8, padding));
    bytes
}

pub async fn upload(app: &Router, token: &str, filename: &str, bytes: Vec<u8>) -> Value {
    let response = app
        .clone()
        .oneshot(request_bytes(
            "POST",
            &format!("/attachments?filename={filename}"),
            token,
            bytes,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::CREATED);
    json_body(response).await
}
