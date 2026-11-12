// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! HTTP `Range` on `GET /attachments/{id}`: a large download resumes and media
//! seeks because the handler streams a requested byte range rather than the
//! whole file. Every case pins one branch of the range parser and the mutation
//! that would turn it red is named on the test.

use axum::body::Body;
use axum::http::{Request, StatusCode, header};
use slimm_server::permissions::Permissions;
use tower::ServiceExt;
use uuid::Uuid;

use crate::attachments::fixtures::*;

/// A PNG whose 8-byte magic satisfies the sniff allowlist, followed by a run
/// of distinct bytes so a returned slice can be checked against its offset
/// rather than only its length.
fn known_png() -> Vec<u8> {
    let mut bytes = png(0);
    bytes.extend_from_slice(b"ABCDEFGHIJKLMNOP");
    bytes
}

/// Uploads `content`, attaches it to a message in a channel `@everyone` can
/// view, and returns the running app, a token that can fetch, the id, and the
/// temp-database guard the caller must hold for the test's lifetime so it is
/// cleaned up on drop rather than leaked.
async fn serve_ready(
    content: Vec<u8>,
) -> (axum::Router, String, String, crate::support::TestDbGuard) {
    let (store, guard) = new_store().await;
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
    let app = app(store.clone());
    let (token, _id) = register(&store, "alice").await;

    let uploaded = upload(&app, &token, "clip.png", content).await;
    let attachment_id = uploaded["id"].as_str().unwrap().to_owned();
    let sent = app
        .clone()
        .oneshot(request_json(
            "POST",
            &format!("/channels/{}/messages", channel.id),
            &token,
            serde_json::json!({
                "id": Uuid::now_v7().to_string(),
                "content": "a clip",
                "attachment_ids": [attachment_id.clone()],
            }),
        ))
        .await
        .unwrap();
    assert_eq!(sent.status(), StatusCode::OK);
    (app, token, attachment_id, guard)
}

fn request_range(uri: &str, token: &str, range: &str) -> Request<Body> {
    Request::builder()
        .method("GET")
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .header(header::RANGE, range)
        .body(Body::empty())
        .unwrap()
}

async fn body_bytes(response: axum::response::Response) -> Vec<u8> {
    axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap()
        .to_vec()
}

#[tokio::test]
async fn a_full_fetch_advertises_ranges_and_a_content_length() {
    let content = known_png();
    let (app, token, id, _guard) = serve_ready(content.clone()).await;

    let response = app
        .oneshot(request_plain("GET", &format!("/attachments/{id}"), &token))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    // Drop the `Accept-Ranges` insert and this fails: a client never tries to resume or seek.
    assert_eq!(
        response.headers().get(header::ACCEPT_RANGES).unwrap(),
        "bytes"
    );
    assert_eq!(
        response.headers().get(header::CONTENT_LENGTH).unwrap(),
        &content.len().to_string()
    );
    assert_eq!(body_bytes(response).await, content);
}

#[tokio::test]
async fn a_satisfiable_range_returns_206_with_exactly_that_slice() {
    let content = known_png();
    let (app, token, id, _guard) = serve_ready(content.clone()).await;

    // Bytes 10..=13 land in the distinct tail ("CDEF"); a wrong seek or missing `.take` shows.
    let response = app
        .oneshot(request_range(
            &format!("/attachments/{id}"),
            &token,
            "bytes=10-13",
        ))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::PARTIAL_CONTENT);
    assert_eq!(
        response.headers().get(header::CONTENT_RANGE).unwrap(),
        &format!("bytes 10-13/{}", content.len())
    );
    assert_eq!(response.headers().get(header::CONTENT_LENGTH).unwrap(), "4");
    assert_eq!(
        response.headers().get(header::ACCEPT_RANGES).unwrap(),
        "bytes"
    );
    assert_eq!(body_bytes(response).await, content[10..=13]);
}

#[tokio::test]
async fn a_suffix_range_returns_the_final_bytes() {
    let content = known_png();
    let total = content.len();
    let (app, token, id, _guard) = serve_ready(content.clone()).await;

    // `bytes=-4` is the last four bytes; a broken suffix branch returns the wrong offsets.
    let response = app
        .oneshot(request_range(
            &format!("/attachments/{id}"),
            &token,
            "bytes=-4",
        ))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::PARTIAL_CONTENT);
    assert_eq!(
        response.headers().get(header::CONTENT_RANGE).unwrap(),
        &format!("bytes {}-{}/{total}", total - 4, total - 1)
    );
    assert_eq!(body_bytes(response).await, content[total - 4..]);
}

#[tokio::test]
async fn an_open_ended_range_runs_to_the_end() {
    let content = known_png();
    let total = content.len();
    let (app, token, id, _guard) = serve_ready(content.clone()).await;

    let response = app
        .oneshot(request_range(
            &format!("/attachments/{id}"),
            &token,
            "bytes=8-",
        ))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::PARTIAL_CONTENT);
    assert_eq!(
        response.headers().get(header::CONTENT_RANGE).unwrap(),
        &format!("bytes 8-{}/{total}", total - 1)
    );
    assert_eq!(body_bytes(response).await, content[8..]);
}

#[tokio::test]
async fn an_unsatisfiable_range_returns_416_with_the_total_size() {
    let content = known_png();
    let total = content.len();
    let (app, token, id, _guard) = serve_ready(content.clone()).await;

    // A start past the end satisfies nothing; `Content-Range` still tells the client the length.
    let response = app
        .oneshot(request_range(
            &format!("/attachments/{id}"),
            &token,
            "bytes=9000-9100",
        ))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::RANGE_NOT_SATISFIABLE);
    assert_eq!(
        response.headers().get(header::CONTENT_RANGE).unwrap(),
        &format!("bytes */{total}")
    );
}

#[tokio::test]
async fn a_multi_range_falls_back_to_the_whole_body() {
    let content = known_png();
    let (app, token, id, _guard) = serve_ready(content.clone()).await;

    // No multipart/byteranges response, so more than one range is served as the full 200.
    let response = app
        .oneshot(request_range(
            &format!("/attachments/{id}"),
            &token,
            "bytes=0-1,4-5",
        ))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(body_bytes(response).await, content);
}

#[tokio::test]
async fn a_malformed_range_is_ignored() {
    let content = known_png();
    let (app, token, id, _guard) = serve_ready(content.clone()).await;

    // A value that is not a byte range is ignored per RFC 9110, not an error: full body.
    let response = app
        .oneshot(request_range(
            &format!("/attachments/{id}"),
            &token,
            "bytes=not-a-range",
        ))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(body_bytes(response).await, content);
}
