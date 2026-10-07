// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A slow but steadily progressing upload must not be cut by the router-wide
//! 30 s request timeout.

use std::time::Duration;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use slimm_server::permissions::Permissions;
use tower::ServiceExt;

use crate::fixtures::*;

async fn streamed_upload(chunks: usize, gap: Duration) -> (StatusCode, Duration) {
    let started = tokio::time::Instant::now();
    let status = upload(chunks, gap, 64, false).await;
    (status, started.elapsed())
}

/// Sends `chunks` chunks `gap` apart, every one after the first `tail` bytes long.
async fn upload(chunks: usize, gap: Duration, tail: usize, paused: bool) -> StatusCode {
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

    let first = png(0);
    let stream = futures_util::stream::unfold(0usize, move |i| {
        let first = first.clone();
        async move {
            if i >= chunks {
                return None;
            }
            if i > 0 {
                tokio::time::sleep(gap).await;
            }
            let chunk = if i == 0 { first } else { vec![0u8; tail] };
            Some((Ok::<_, std::io::Error>(bytes_from(chunk)), i + 1))
        }
    });
    let request = Request::builder()
        .method("POST")
        .uri("/attachments?filename=slow.png")
        .header("authorization", format!("Bearer {token}"))
        .body(Body::from_stream(stream))
        .unwrap();
    // Paused only now: setup opens the pool, whose connect timeout a paused clock would fire.
    if paused {
        tokio::time::pause();
    }
    app.oneshot(request).await.unwrap().status()
}

fn bytes_from(v: Vec<u8>) -> axum::body::Bytes {
    axum::body::Bytes::from(v)
}

#[tokio::test]
async fn control_a_quick_chunked_upload_succeeds() {
    let (status, took) = streamed_upload(4, Duration::from_millis(200)).await;
    assert_eq!(status, StatusCode::CREATED, "took {took:?}");
}

/// 4 chunks, one every 11 s: 33 s total, every inter-chunk gap under the 15 s
/// body idle timeout, a few hundred bytes against a 4096 byte ceiling.
#[tokio::test]
async fn a_slow_but_progressing_upload_is_not_cut_at_30_seconds() {
    let (status, took) = streamed_upload(4, Duration::from_secs(11)).await;
    assert_eq!(
        status,
        StatusCode::CREATED,
        "a steadily progressing upload answered {status} after {took:?}"
    );
}

/// The exemption from the total-time timeout must not let a stalled sender
/// hold the connection: a 16 s gap is over the 15 s body idle timeout.
#[tokio::test]
async fn a_stalled_upload_is_still_cut() {
    let (status, took) = streamed_upload(2, Duration::from_secs(16)).await;
    assert_ne!(status, StatusCode::CREATED, "a stalled upload was accepted");
    assert!(took < Duration::from_secs(30), "cut only after {took:?}");
}

/// A sender that never stalls past the body idle timeout but drips a byte every
/// 10 s is still cut once the upload's total time runs out. On a paused clock,
/// so 33 simulated minutes take a moment.
#[tokio::test]
async fn a_dripping_upload_is_cut_by_the_total_upload_timeout() {
    let started = tokio::time::Instant::now();
    let status = upload(200, Duration::from_secs(10), 1, true).await;
    let took = started.elapsed();
    assert_ne!(
        status,
        StatusCode::CREATED,
        "a dripping upload ran {took:?}"
    );
    assert!(
        took < Duration::from_secs(31 * 60),
        "cut only after {took:?}"
    );
    assert!(
        took >= Duration::from_secs(29 * 60),
        "cut early after {took:?}"
    );
}
