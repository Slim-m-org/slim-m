// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A malformed JSON body, a query string that will not parse, and a body over
//! the configured size limit all used to answer with axum's own plain-text
//! rejection rather than the `{"error": ...}` shape every other response
//! uses. `http::extract::{Json, Query, Bytes}` close that gap; these tests
//! send genuinely broken input and pin both the status and the response
//! shape so a regression here is a red test, not a silent client-parsing bug.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode, header};
use serde_json::Value;
use slimm_server::auth::Auth;
use slimm_server::media::Media;
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use tower::ServiceExt;

mod support;
use uuid::Uuid;

/// Builds a router sharing `store` and `media`, so a test can hand it a
/// media handle with a small size ceiling instead of the 10 MiB test default.
fn app(store: Store, media: Media) -> Router {
    let auth = Auth::new(2).expect("auth service");
    support::app::builder(store)
        .auth(auth)
        .media(media)
        .router()
}

/// A member with a session and a channel they may post in. Holds ATTACH_FILES
/// so the oversized-upload case reaches the size check: the upload handler
/// refuses a caller lacking it before reading the body at all, which is a 403,
/// not the 413 this file's malformed-body test means to exercise.
async fn registered_member(store: &Store) -> (String, String) {
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL
                .union(Permissions::SEND_MESSAGES)
                .union(Permissions::ATTACH_FILES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let account = store
        .create_account("alice", "Alice", "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    let tokens = store.open_session(account.id, "cli").await.unwrap();
    (tokens.access_token, channel.id.to_string())
}

/// The status, content-type, and `{"error": ...}` shape every malformed
/// extraction should now share, regardless of which extractor rejected it.
async fn assert_uniform_error(
    response: axum::response::Response,
    expected_status: StatusCode,
) -> String {
    assert_eq!(response.status(), expected_status);
    let content_type = response
        .headers()
        .get(header::CONTENT_TYPE)
        .expect("an error response always carries a content type")
        .to_str()
        .unwrap()
        .to_owned();
    assert!(
        content_type.starts_with("application/json"),
        "expected a JSON content type, got {content_type}"
    );
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    let body: Value =
        serde_json::from_slice(&bytes).expect("the body must parse as JSON, not axum's plain text");
    let error = body
        .as_object()
        .expect("the body must be a JSON object")
        .get("error")
        .expect("the body must carry an \"error\" key")
        .as_str()
        .expect("\"error\" must be a string")
        .to_owned();
    assert!(!error.is_empty(), "the error message must not be empty");
    error
}

#[tokio::test]
async fn malformed_json_syntax_is_a_uniform_json_error() {
    let (store, _db) = support::new_store("slimm-malformed-test").await;
    let (token, channel_id) = registered_member(&store).await;
    let app = app(store, Media::for_tests());

    let request = Request::builder()
        .method("POST")
        .uri(format!("/channels/{channel_id}/messages"))
        .header("authorization", format!("Bearer {token}"))
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from("{not valid json"))
        .unwrap();
    let response = app.oneshot(request).await.unwrap();

    let error = assert_uniform_error(response, StatusCode::BAD_REQUEST).await;
    assert!(
        !error.contains("{not valid json"),
        "the raw body must never be echoed back: {error}"
    );
}

#[tokio::test]
async fn json_missing_a_required_field_is_a_uniform_json_error() {
    let (store, _db) = support::new_store("slimm-malformed-test").await;
    let (token, channel_id) = registered_member(&store).await;
    let app = app(store, Media::for_tests());

    // Valid JSON, but `SendRequest` also requires `content`.
    let body = serde_json::json!({ "id": Uuid::now_v7().to_string() }).to_string();
    let request = Request::builder()
        .method("POST")
        .uri(format!("/channels/{channel_id}/messages"))
        .header("authorization", format!("Bearer {token}"))
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(body))
        .unwrap();
    let response = app.oneshot(request).await.unwrap();

    let error = assert_uniform_error(response, StatusCode::BAD_REQUEST).await;
    assert!(
        error.contains("content"),
        "a missing-field error should name the field: {error}"
    );
    assert!(
        !error.contains("SendRequest") && !error.contains("alloc::"),
        "the message must not leak a Rust type path: {error}"
    );
}

#[tokio::test]
async fn malformed_query_string_is_a_uniform_json_error() {
    let (store, _db) = support::new_store("slimm-malformed-test").await;
    let (token, channel_id) = registered_member(&store).await;
    let app = app(store, Media::for_tests());

    // `limit` is an `Option<i64>`; a non-numeric value cannot parse as one.
    let request = Request::builder()
        .method("GET")
        .uri(format!("/channels/{channel_id}/messages?limit=notanumber"))
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap();
    let response = app.oneshot(request).await.unwrap();

    assert_uniform_error(response, StatusCode::BAD_REQUEST).await;
}

#[tokio::test]
async fn oversized_json_body_is_a_uniform_json_error() {
    let (store, _db) = support::new_store("slimm-malformed-test").await;
    let (token, channel_id) = registered_member(&store).await;
    let app = app(store, Media::for_tests());

    // Comfortably over the 64 KiB message body limit.
    let oversized_content = "a".repeat(70_000);
    let body = serde_json::json!({
        "id": Uuid::now_v7().to_string(),
        "content": oversized_content,
    })
    .to_string();
    let request = Request::builder()
        .method("POST")
        .uri(format!("/channels/{channel_id}/messages"))
        .header("authorization", format!("Bearer {token}"))
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(body))
        .unwrap();
    let response = app.oneshot(request).await.unwrap();

    assert_uniform_error(response, StatusCode::PAYLOAD_TOO_LARGE).await;
}

#[tokio::test]
async fn oversized_raw_body_is_a_uniform_json_error() {
    let (store, _db) = support::new_store("slimm-malformed-test").await;
    let (token, _channel_id) = registered_member(&store).await;
    // A tiny ceiling, so exceeding it does not need megabytes of bytes.
    let (root, _mediadir) = support::TestDirGuard::new("slimm-malformed-media");
    let media = Media::new(root, 16).expect("create temp media directories");
    let app = app(store, media);

    let request = Request::builder()
        .method("POST")
        .uri("/attachments")
        .header("authorization", format!("Bearer {token}"))
        .body(Body::from(vec![0u8; 1024]))
        .unwrap();
    let response = app.oneshot(request).await.unwrap();

    assert_uniform_error(response, StatusCode::PAYLOAD_TOO_LARGE).await;
}
