// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
use axum::Router;
use axum::http::{StatusCode, header};
use axum::response::IntoResponse;
use axum::routing::get;
use url::Url;

use super::*;

async fn upstream() -> u16 {
    let app = Router::new()
        .route(
            "/ok",
            get(|| async {
                (
                    [(header::CONTENT_TYPE, "application/json")],
                    "{\"up\":true}",
                )
            }),
        )
        .route(
            "/moved",
            get(|| async {
                (
                    StatusCode::FOUND,
                    [(header::LOCATION, "http://elsewhere.example/")],
                )
                    .into_response()
            }),
        )
        .route(
            "/big",
            get(|| async { "x".repeat(MAX_RESPONSE_BODY_BYTES + 10) }),
        );
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    port
}

async fn run(allow_local: bool, url: String) -> Result<FetchResponse, FetchRefused> {
    let fetcher = ReqwestFetcher::new(Handle::current(), allow_local);
    tokio::task::spawn_blocking(move || {
        fetcher.fetch(FetchRequest {
            method: reqwest::Method::GET,
            url: Url::parse(&url).unwrap(),
            headers: Vec::new(),
            body: None,
        })
    })
    .await
    .unwrap()
}

#[tokio::test(flavor = "multi_thread")]
async fn a_local_address_is_refused_without_the_second_approval() {
    let port = upstream().await;
    for url in [
        format!("http://127.0.0.1:{port}/ok"),
        format!("http://localhost:{port}/ok"),
    ] {
        let err = run(false, url.clone()).await.unwrap_err();
        assert_eq!(err.0, LOCAL_REFUSED, "{url}");
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn with_the_local_approval_the_request_goes_through() {
    let port = upstream().await;
    let response = run(true, format!("http://localhost:{port}/ok"))
        .await
        .unwrap();
    assert_eq!(response.status, 200);
    assert_eq!(response.body, "{\"up\":true}");
    assert_eq!(response.content_type.as_deref(), Some("application/json"));
    assert!(!response.truncated);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_redirect_is_handed_back_not_followed() {
    let port = upstream().await;
    let response = run(true, format!("http://127.0.0.1:{port}/moved"))
        .await
        .unwrap();
    assert_eq!(response.status, 302);
    assert_eq!(
        response.location.as_deref(),
        Some("http://elsewhere.example/")
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_large_body_is_cut_at_the_cap_and_flagged() {
    let port = upstream().await;
    let response = run(true, format!("http://127.0.0.1:{port}/big"))
        .await
        .unwrap();
    assert!(response.truncated);
    assert_eq!(response.body.len(), MAX_RESPONSE_BODY_BYTES);
}
