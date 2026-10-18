// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The connection test routes: they need a session, move only capped throwaway bytes, and are
//! rate limited so a loop cannot turn them into a bandwidth tap.
#![allow(dead_code)]

use axum::body::Body;
use axum::http::{Request, StatusCode};
use tower::ServiceExt;

mod support;
mod totp_support;

use totp_support::{app, json_body, member, new_store, request};

const CAP: usize = 25 * 1024 * 1024;

fn upload_request(token: &str, bytes: usize) -> Request<Body> {
    Request::builder()
        .method("POST")
        .uri("/diagnostics/upload")
        .header("authorization", format!("Bearer {token}"))
        .header("content-length", bytes)
        .body(Body::from(vec![7u8; bytes]))
        .unwrap()
}

#[tokio::test]
async fn every_route_needs_a_session() {
    let (store, auth, _guard) = new_store("slimm-diag-auth").await;
    let router = app(store, auth);
    for (method, uri) in [
        ("GET", "/diagnostics/ping"),
        ("GET", "/diagnostics/download?bytes=1024"),
        ("POST", "/diagnostics/upload"),
    ] {
        let response = router
            .clone()
            .oneshot(request(method, uri, None, None))
            .await
            .unwrap();
        assert_eq!(
            response.status(),
            StatusCode::UNAUTHORIZED,
            "{method} {uri}"
        );
    }
}

#[tokio::test]
async fn ping_answers_with_the_server_clock() {
    let (store, auth, _guard) = new_store("slimm-diag-ping").await;
    let router = app(store.clone(), auth.clone());
    let (token, _) = member(&store, &auth, "alice").await;
    let response = router
        .oneshot(request("GET", "/diagnostics/ping", Some(&token), None))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    assert!(
        json_body(response).await["server_time_ms"]
            .as_i64()
            .unwrap()
            > 0
    );
}

#[tokio::test]
async fn download_sends_exactly_the_bytes_asked_for() {
    let (store, auth, _guard) = new_store("slimm-diag-download").await;
    let router = app(store.clone(), auth.clone());
    let (token, _) = member(&store, &auth, "alice").await;
    for bytes in [1usize, 65_536, 200_001, CAP] {
        let response = router
            .clone()
            .oneshot(request(
                "GET",
                &format!("/diagnostics/download?bytes={bytes}"),
                Some(&token),
                None,
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK, "{bytes}");
        assert_eq!(response.headers()["cache-control"], "no-store");
        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        assert_eq!(body.len(), bytes);
    }
}

#[tokio::test]
async fn download_refuses_zero_and_anything_over_the_cap() {
    let (store, auth, _guard) = new_store("slimm-diag-download-cap").await;
    let router = app(store.clone(), auth.clone());
    let (token, _) = member(&store, &auth, "alice").await;
    for bytes in ["0", &(CAP + 1).to_string(), "-5", "lots"] {
        let response = router
            .clone()
            .oneshot(request(
                "GET",
                &format!("/diagnostics/download?bytes={bytes}"),
                Some(&token),
                None,
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::BAD_REQUEST, "bytes={bytes}");
    }
}

#[tokio::test]
async fn upload_counts_what_it_was_sent_and_keeps_nothing() {
    let (store, auth, _guard) = new_store("slimm-diag-upload").await;
    let router = app(store.clone(), auth.clone());
    let (token, _) = member(&store, &auth, "alice").await;
    let response = router
        .oneshot(upload_request(&token, 3 * 1024 * 1024 + 5))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let body = json_body(response).await;
    assert_eq!(body["bytes"], 3 * 1024 * 1024 + 5);
    assert!(body["duration_ms"].is_u64());
}

#[tokio::test]
async fn upload_over_the_cap_is_refused_before_it_is_read() {
    let (store, auth, _guard) = new_store("slimm-diag-upload-cap").await;
    let router = app(store.clone(), auth.clone());
    let (token, _) = member(&store, &auth, "alice").await;
    let declared = Request::builder()
        .method("POST")
        .uri("/diagnostics/upload")
        .header("authorization", format!("Bearer {token}"))
        .header("content-length", CAP + 1)
        .body(Body::from_stream(futures_util::stream::once(async {
            Err::<Vec<u8>, std::io::Error>(std::io::Error::other("the body must not be read"))
        })))
        .unwrap();
    let response = router.clone().oneshot(declared).await.unwrap();
    assert_eq!(response.status(), StatusCode::PAYLOAD_TOO_LARGE);

    let undeclared = Request::builder()
        .method("POST")
        .uri("/diagnostics/upload")
        .header("authorization", format!("Bearer {token}"))
        .body(Body::from_stream(futures_util::stream::iter(
            (0..30).map(|_| Ok::<_, std::io::Error>(vec![0u8; 1024 * 1024])),
        )))
        .unwrap();
    let response = router.oneshot(undeclared).await.unwrap();
    assert_eq!(response.status(), StatusCode::PAYLOAD_TOO_LARGE);
}

#[tokio::test]
async fn transfers_are_rate_limited_per_account() {
    let (store, auth, _guard) = new_store("slimm-diag-limit").await;
    let router = app(store.clone(), auth.clone());
    let (token, _) = member(&store, &auth, "alice").await;
    let (other, _) = member(&store, &auth, "bob").await;
    let mut limited = None;
    for attempt in 0..20 {
        let response = router
            .clone()
            .oneshot(request(
                "GET",
                "/diagnostics/download?bytes=1024",
                Some(&token),
                None,
            ))
            .await
            .unwrap();
        if response.status() == StatusCode::TOO_MANY_REQUESTS {
            limited = Some(attempt);
            break;
        }
    }
    assert_eq!(limited, Some(12), "the burst is twelve transfers");
    let response = router
        .oneshot(request(
            "GET",
            "/diagnostics/download?bytes=1024",
            Some(&other),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(
        response.status(),
        StatusCode::OK,
        "another account has its own budget"
    );
}
