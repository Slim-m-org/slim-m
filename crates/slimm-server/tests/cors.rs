// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Cross-origin access: what a browser is actually told, for a configured
//! origin, an unconfigured deployment, and an origin that is not on the list.
//!
//! Driven against the real router rather than the layer alone, because the
//! bug this closes was not a wrong header, it was a preflight reaching axum's
//! method router and coming back 405 with no CORS headers at all.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use slimm_server::config::Config;
use slimm_server::cors::CorsPolicy;
use slimm_server::db;
use slimm_server::http::{self};
use slimm_server::store::Store;
use tower::ServiceExt;

mod support;

const WEB_CLIENT: &str = "http://localhost:8099";
const SOMEBODY_ELSE: &str = "https://evil.example.com";

async fn app(policy: CorsPolicy) -> (Router, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new("slimm-cors-test");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    let router = policy.apply(http::router(support::app::state(Store::new(pool))));
    (router, guard)
}

async fn configured() -> (Router, support::TestDbGuard) {
    app(CorsPolicy::for_test(WEB_CLIENT).expect("a valid origin")).await
}

/// The preflight a browser sends before any JSON-bodied request.
fn preflight(origin: &str) -> Request<Body> {
    Request::builder()
        .method("OPTIONS")
        .uri("/auth/login")
        .header("origin", origin)
        .header("access-control-request-method", "POST")
        .header("access-control-request-headers", "content-type")
        .body(Body::empty())
        .unwrap()
}

fn simple_get(origin: &str) -> Request<Body> {
    Request::builder()
        .method("GET")
        .uri("/version")
        .header("origin", origin)
        .body(Body::empty())
        .unwrap()
}

async fn headers_of(app: Router, request: Request<Body>) -> (StatusCode, axum::http::HeaderMap) {
    let response = app.oneshot(request).await.unwrap();
    (response.status(), response.headers().clone())
}

fn header<'a>(headers: &'a axum::http::HeaderMap, name: &str) -> Option<&'a str> {
    headers.get(name).map(|value| value.to_str().unwrap())
}

/// The preflight is left to fall through to the method router, which is what
/// produced the 405 that started this. Deny by default means the browser
/// refuses the real request, not that the server pretends to allow it.
#[tokio::test]
async fn an_unconfigured_deployment_sends_no_cors_headers() {
    let (router, _guard) = app(CorsPolicy::disabled()).await;
    let (status, headers) = headers_of(router, simple_get(WEB_CLIENT)).await;
    assert_eq!(status, StatusCode::OK, "the request itself still succeeds");
    assert_eq!(header(&headers, "access-control-allow-origin"), None);

    let (router, _guard) = app(CorsPolicy::disabled()).await;
    let (status, headers) = headers_of(router, preflight(WEB_CLIENT)).await;
    assert_eq!(status, StatusCode::METHOD_NOT_ALLOWED);
    assert_eq!(header(&headers, "access-control-allow-origin"), None);
}

#[tokio::test]
async fn a_configured_origin_is_echoed_back() {
    let (router, _guard) = configured().await;
    let (status, headers) = headers_of(router, simple_get(WEB_CLIENT)).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        header(&headers, "access-control-allow-origin"),
        Some(WEB_CLIENT)
    );
    // Without this a shared cache could serve one origin's allow header to another.
    let vary = header(&headers, "vary").expect("a per-origin answer must vary on origin");
    assert!(vary.to_ascii_lowercase().contains("origin"), "{vary}");
}

/// A browser hides every response header from script unless the server names
/// it. The web client could not read `Retry-After` on a 429, so it guessed.
#[tokio::test]
async fn retry_after_is_exposed_to_a_browser_script() {
    let (router, _guard) = configured().await;
    let (_, headers) = headers_of(router, simple_get(WEB_CLIENT)).await;
    let exposed = header(&headers, "access-control-expose-headers")
        .unwrap_or_default()
        .to_ascii_lowercase();
    assert!(exposed.contains("retry-after"), "exposed: {exposed:?}");
}

#[tokio::test]
async fn another_origin_is_refused() {
    let (router, _guard) = configured().await;
    let (status, headers) = headers_of(router, simple_get(SOMEBODY_ELSE)).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        header(&headers, "access-control-allow-origin"),
        None,
        "an origin that is not on the list must never be echoed"
    );

    let (router, _guard) = configured().await;
    let (_, headers) = headers_of(router, preflight(SOMEBODY_ELSE)).await;
    assert_eq!(header(&headers, "access-control-allow-origin"), None);
}

#[tokio::test]
async fn a_preflight_is_answered_rather_than_405() {
    let (router, _guard) = configured().await;
    let (status, headers) = headers_of(router, preflight(WEB_CLIENT)).await;
    assert!(
        status.is_success(),
        "a preflight must be answered by the layer, not reach the method router: {status}"
    );
    assert_eq!(
        header(&headers, "access-control-allow-origin"),
        Some(WEB_CLIENT)
    );

    let methods = header(&headers, "access-control-allow-methods").expect("allowed methods");
    for method in ["GET", "POST", "PUT", "PATCH", "DELETE"] {
        assert!(methods.contains(method), "{method} missing from {methods}");
    }

    let allowed = header(&headers, "access-control-allow-headers")
        .expect("allowed headers")
        .to_ascii_lowercase();
    assert!(allowed.contains("authorization"), "{allowed}");
    assert!(allowed.contains("content-type"), "{allowed}");

    assert!(header(&headers, "access-control-max-age").is_some());
}

#[tokio::test]
async fn credentials_are_never_allowed() {
    // This API's bearer token is attached explicitly by the client and is
    // never ambient, so allowing credentials would add only cookie authority.
    for request in [preflight(WEB_CLIENT), simple_get(WEB_CLIENT)] {
        let (router, _guard) = configured().await;
        let (_, headers) = headers_of(router, request).await;
        assert_eq!(
            header(&headers, "access-control-allow-credentials"),
            None,
            "allow-credentials must never be sent"
        );
    }
}

#[tokio::test]
async fn a_post_from_an_allowed_origin_reaches_the_handler() {
    // The preflight passing is only half of it: the real request has to carry
    // the allow header too, or the browser discards the response it got.
    let request = Request::builder()
        .method("POST")
        .uri("/auth/login")
        .header("origin", WEB_CLIENT)
        .header("content-type", "application/json")
        .body(Body::from(
            r#"{"username":"nobody","password":"wrong-password","device_name":"web"}"#,
        ))
        .unwrap();
    let (router, _guard) = configured().await;
    let (status, headers) = headers_of(router, request).await;
    assert_eq!(
        status,
        StatusCode::UNAUTHORIZED,
        "the handler ran and rejected the credentials, rather than CORS refusing it"
    );
    assert_eq!(
        header(&headers, "access-control-allow-origin"),
        Some(WEB_CLIENT)
    );
}
