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

const ROOMY: Duration = Duration::from_secs(5);

async fn run_with(
    fetcher: ReqwestFetcher,
    url: String,
    remaining: Duration,
) -> Result<FetchResponse, FetchRefused> {
    tokio::task::spawn_blocking(move || {
        fetcher.fetch(
            FetchRequest {
                method: reqwest::Method::GET,
                url: Url::parse(&url).unwrap(),
                headers: Vec::new(),
                body: None,
            },
            remaining,
        )
    })
    .await
    .unwrap()
}

async fn run(allow_local: bool, url: String) -> Result<FetchResponse, FetchRefused> {
    run_with(
        ReqwestFetcher::new(Handle::current(), allow_local),
        url,
        ROOMY,
    )
    .await
}

async fn run_unguarded(url: String) -> Result<FetchResponse, FetchRefused> {
    run_with(ReqwestFetcher::unguarded(Handle::current()), url, ROOMY).await
}

#[tokio::test(flavor = "multi_thread")]
async fn a_local_address_is_refused_without_the_second_approval() {
    let port = upstream().await;
    for url in [
        format!("http://127.0.0.1:{port}/ok"),
        format!("http://localhost:{port}/ok"),
        format!("http://192.168.1.10:{port}/ok"),
    ] {
        let err = run(false, url.clone()).await.unwrap_err();
        assert_eq!(err.0, LOCAL_REFUSED, "{url}");
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn the_second_approval_never_reaches_loopback_link_local_or_metadata() {
    let port = upstream().await;
    for url in [
        format!("http://127.0.0.1:{port}/ok"),
        format!("http://localhost:{port}/ok"),
        format!("http://[::1]:{port}/ok"),
        "http://169.254.169.254/latest/meta-data".to_owned(),
        "http://[fe80::1]/".to_owned(),
        "http://0.0.0.0/".to_owned(),
    ] {
        let err = run(true, url.clone()).await.unwrap_err();
        assert_eq!(err.0, LOCAL_REFUSED, "{url}");
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn the_second_approval_refuses_the_servers_own_private_address() {
    let port = upstream().await;
    // Connecting a UDP socket sends nothing; it only picks this host's outbound address.
    let own = std::net::UdpSocket::bind("0.0.0.0:0")
        .and_then(|s| s.connect("192.0.2.1:9").map(|()| s))
        .and_then(|s| s.local_addr())
        .map(|a| a.ip());
    let Ok(ip @ std::net::IpAddr::V4(v4)) = own else {
        return;
    };
    if !v4.is_private() {
        return;
    }
    let err = run(true, format!("http://{ip}:{port}/ok"))
        .await
        .unwrap_err();
    assert_eq!(err.0, LOCAL_REFUSED, "{ip}");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_request_that_clears_the_guard_goes_through() {
    let port = upstream().await;
    let response = run_unguarded(format!("http://localhost:{port}/ok"))
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
    let response = run_unguarded(format!("http://127.0.0.1:{port}/moved"))
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
    let response = run_unguarded(format!("http://127.0.0.1:{port}/big"))
        .await
        .unwrap();
    assert!(response.truncated);
    assert_eq!(response.body.len(), MAX_RESPONSE_BODY_BYTES);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_slow_upstream_ends_inside_the_budget_with_a_clean_timeout() {
    let app = Router::new().route(
        "/slow",
        get(|| async {
            tokio::time::sleep(Duration::from_secs(5)).await;
            "late"
        }),
    );
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let started = std::time::Instant::now();
    let fetcher = ReqwestFetcher::unguarded(Handle::current());
    let err = run_with(
        fetcher,
        format!("http://127.0.0.1:{port}/slow"),
        Duration::from_millis(600),
    )
    .await
    .unwrap_err();
    assert_eq!(err.0, TIMED_OUT);
    assert!(
        started.elapsed() < Duration::from_secs(2),
        "{:?}",
        started.elapsed()
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn no_request_starts_when_the_run_has_no_time_left() {
    let port = upstream().await;
    let fetcher = ReqwestFetcher::unguarded(Handle::current());
    let err = run_with(fetcher, format!("http://127.0.0.1:{port}/ok"), RUN_HEADROOM)
        .await
        .unwrap_err();
    assert_eq!(err.0, TIMED_OUT);
}
