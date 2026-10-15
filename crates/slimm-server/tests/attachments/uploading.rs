// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What `POST /attachments` accepts: the size ceiling, the byte-sniffed
//! content-type allowlist, and the rate limit on a sustained flood.

use axum::body::Body;
use axum::http::{Request, StatusCode};
use slimm_server::permissions::Permissions;
use tower::ServiceExt;

use crate::fixtures::*;

#[tokio::test]
async fn an_oversized_upload_is_refused() {
    let (store, _guard) = new_store().await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::ATTACH_FILES),
            true,
        )
        .await
        .unwrap();
    let app = app(store.clone());
    let (token, _id) = register(&store, "alice").await;

    let too_big = png(TEST_MAX_ATTACHMENT_BYTES as usize + 1);
    let response = app
        .clone()
        .oneshot(request_bytes(
            "POST",
            "/attachments?filename=big.png",
            &token,
            too_big,
        ))
        .await
        .unwrap();
    assert!(
        !response.status().is_success(),
        "a body over the configured ceiling must be refused, got {}",
        response.status()
    );
}

/// The over-ceiling refusal is specifically a 413, not a generic 400: a
/// caller needs to tell "make it smaller" apart from a malformed request. A
/// declared Content-Length over the ceiling is refused before a byte streams.
#[tokio::test]
async fn an_oversized_upload_is_refused_as_413() {
    let (store, _guard) = new_store().await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::ATTACH_FILES),
            true,
        )
        .await
        .unwrap();
    let app = app(store.clone());
    let (token, _id) = register(&store, "alice").await;

    let response = app
        .clone()
        .oneshot(request_bytes(
            "POST",
            "/attachments?filename=big.png",
            &token,
            png(TEST_MAX_ATTACHMENT_BYTES as usize + 1),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::PAYLOAD_TOO_LARGE);
}

/// A chunked upload sends no Content-Length, so the declared-length fast-fail
/// cannot catch it - only the running byte count as the body streams to disk
/// can, which is the guard that keeps a 1 GiB ceiling from meaning a 1 GiB
/// buffer. Mutating `stream_attachment` to drop its `size > max_bytes` check
/// turns this red (the upload would be accepted).
#[tokio::test]
async fn a_chunked_upload_over_the_ceiling_is_still_refused() {
    let (store, _guard) = new_store().await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::ATTACH_FILES),
            true,
        )
        .await
        .unwrap();
    let app = app(store.clone());
    let (token, _id) = register(&store, "alice").await;

    // A stream body carries no Content-Length, so only the running total refuses.
    let oversized = png(TEST_MAX_ATTACHMENT_BYTES as usize + 1);
    let chunks: Vec<Result<Vec<u8>, std::io::Error>> =
        oversized.chunks(256).map(|c| Ok(c.to_vec())).collect();
    let request = Request::builder()
        .method("POST")
        .uri("/attachments?filename=streamed.png")
        .header("authorization", format!("Bearer {token}"))
        .body(Body::from_stream(futures_util::stream::iter(chunks)))
        .unwrap();
    let response = app.clone().oneshot(request).await.unwrap();

    assert_eq!(response.status(), StatusCode::PAYLOAD_TOO_LARGE);
}

/// The filename and an explicit Content-Type header both claim an image, but
/// the bytes are HTML. Neither signal is trusted - only the bytes are
/// sniffed - so the stored type is whatever the bytes actually are
/// (`text/plain`, the last-resort fallback for plausibly readable text; see
/// `media::content_type`'s module doc), never the lying `image/png` either
/// signal claimed. This upload succeeds rather than being refused: HTML text
/// is exactly the reference-material shape this allowlist was widened to
/// admit, and it is inert once stored, since `text/plain` is never served
/// inline (see `html_and_svg_sniffed_as_text_are_served_as_a_forced_download`
/// in `http::attachments`, which drives the real serving handler on this
/// same content and asserts the forced download).
#[tokio::test]
async fn the_sniffed_type_wins_over_a_lying_filename_and_content_type_header() {
    let (store, _guard) = new_store().await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::ATTACH_FILES),
            true,
        )
        .await
        .unwrap();
    let app = app(store.clone());
    let (token, _id) = register(&store, "alice").await;

    let html = b"<html><body><script>alert(1)</script></body></html>".to_vec();
    let request = Request::builder()
        .method("POST")
        .uri("/attachments?filename=totally-a-photo.png")
        .header("authorization", format!("Bearer {token}"))
        .header("content-type", "image/png")
        .body(Body::from(html))
        .unwrap();
    let response = app.clone().oneshot(request).await.unwrap();
    assert_eq!(response.status(), StatusCode::CREATED);
    let stored = json_body(response).await;
    assert_eq!(
        stored["content_type"], "text/plain",
        "the bytes decide, not the filename or the claimed header"
    );
}

/// Bytes matching no signature and failing the `text/plain` fallback too
/// (a disk image, an installer) are kept as a generic forced download.
#[tokio::test]
async fn bytes_matching_nothing_are_kept_as_a_generic_download() {
    let (store, _guard) = new_store().await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::ATTACH_FILES),
            true,
        )
        .await
        .unwrap();
    let app = app(store.clone());
    let (token, _id) = register(&store, "alice").await;

    let garbage = vec![0x00, 0x01, 0x02, 0x03, 0xC3, 0x28];
    let response = app
        .clone()
        .oneshot(request_bytes(
            "POST",
            "/attachments?filename=mystery.bin",
            &token,
            garbage,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::CREATED);
    let stored = json_body(response).await;
    assert_eq!(stored["content_type"], "application/octet-stream");
    assert_eq!(stored["filename"], "mystery.bin");
}

#[tokio::test]
async fn uploads_are_rate_limited() {
    let (store, _guard) = new_store().await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::ATTACH_FILES),
            true,
        )
        .await
        .unwrap();
    let app = app(store.clone());
    let (token, _id) = register(&store, "alice").await;

    let mut statuses = Vec::new();
    for i in 0..20 {
        let response = app
            .clone()
            .oneshot(request_bytes(
                "POST",
                &format!("/attachments?filename=f{i}.png"),
                &token,
                png(i),
            ))
            .await
            .unwrap();
        statuses.push(response.status());
    }

    assert!(
        statuses.contains(&StatusCode::CREATED),
        "the first uploads inside the burst are answered: {statuses:?}"
    );
    assert!(
        statuses.contains(&StatusCode::TOO_MANY_REQUESTS),
        "a sustained upload flood must be refused: {statuses:?}"
    );
}

/// Uploading asks for ATTACH_FILES deployment-wide, which until this existed
/// it did not ask for at all: the handler had no permission check of any
/// kind, so a member denied attachments everywhere - or one currently timed
/// out - could still write bytes into media storage and only be stopped one
/// step later, when the id was attached to a message.
///
/// Deployment-wide rather than per-channel because an upload names no
/// channel; the per-channel bit is still checked when the id is used.
#[tokio::test]
async fn uploading_needs_the_attach_files_permission() {
    let (store, _guard) = new_store().await;
    store
        .create_role("everyone", Permissions::VIEW_CHANNEL, true)
        .await
        .unwrap();
    let app = app(store.clone());
    let (token, _id) = register(&store, "alice").await;

    let response = app
        .clone()
        .oneshot(request_bytes(
            "POST",
            "/attachments?filename=nope.png",
            &token,
            png(16),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
}
