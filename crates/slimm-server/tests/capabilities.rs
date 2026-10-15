// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The capability handshake: `/version` names the safety routes this build
//! serves, and it names them because the router really serves them.
//!
//! The point of these tests is the derivation, not the current answer. A
//! hardcoded list would satisfy the first test here and fail the rest, which
//! is the whole reason the rest exist.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use axum::routing::{get, post};
use serde_json::Value;
use slimm_server::auth::Auth;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::http::capability::{Capability, served_by};
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::Store;
use tower::ServiceExt;

mod support;

async fn app() -> (Router, support::TestDbGuard) {
    let (database_path, guard) = support::TestDbGuard::new("slimm-capabilities-test");
    let pool = db::connect(&Config {
        port: 0,
        database_path,
        hash_concurrency: 2,
        ..Config::default()
    })
    .await
    .unwrap();
    let router = http::router(AppState {
        store: Store::new(pool),
        auth: Auth::new(2).unwrap(),
        hub: Hub::new(),
        limiter: RateLimiter::new(),
        push: PushSender::disabled(),
        voice: slimm_server::voice::VoiceService::disabled(),
        media: slimm_server::media::Media::for_tests(),
        gifs: slimm_server::http::gifs::GifSearch::disabled(),
        link_previews: slimm_server::http::link_preview::LinkPreviews::disabled(),
        dock: slimm_server::http::dock::Dock::disabled(),
        code_runner: slimm_server::code_runner::CodeRunner::disabled(),
    });
    (router, guard)
}

#[tokio::test]
async fn the_real_router_serves_every_capability() {
    let (router, _guard) = app().await;
    assert_eq!(
        served_by(router).await,
        vec![
            Capability::Block,
            Capability::Report,
            Capability::Webhook,
            Capability::UploadSessions,
        ],
    );
}

#[tokio::test]
async fn version_advertises_what_the_router_serves() {
    let (router, _guard) = app().await;
    let response = router
        .oneshot(
            Request::builder()
                .method("GET")
                .uri("/version")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let bytes = axum::body::to_bytes(response.into_body(), 64 * 1024)
        .await
        .unwrap();
    let body: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(
        body["capabilities"],
        serde_json::json!(["block", "report", "webhooks", "upload_sessions"])
    );
}

/// The derivation has to be able to say no, or advertising yes proves nothing.
#[tokio::test]
async fn a_router_without_the_safety_routes_advertises_neither() {
    let router = Router::new().route("/healthz", get(|| async { "ok" }));
    assert_eq!(served_by(router).await, Vec::new());
}

/// `GET /reports` is the moderator's queue and `POST /reports` is a member
/// filing one. A deployment that kept the queue and dropped the intake offers
/// no way to report anything, and must not be read as if it did.
#[tokio::test]
async fn the_moderator_queue_alone_is_not_a_way_to_report() {
    let router = Router::new().route("/reports", get(|| async { "[]" }));
    assert!(!served_by(router).await.contains(&Capability::Report));
}

/// The probe must find a route it is not the only method on: `/blocks/{id}`
/// carries both block and unblock, and `/reports` carries the queue too.
#[tokio::test]
async fn a_path_shared_with_another_method_still_counts() {
    let router = Router::new()
        .route(
            "/blocks/{user_id}",
            post(|| async { StatusCode::NO_CONTENT }).delete(|| async { StatusCode::NO_CONTENT }),
        )
        .route("/reports", get(|| async { "[]" }).post(|| async { "{}" }));
    assert_eq!(
        served_by(router).await,
        vec![Capability::Block, Capability::Report],
    );
}

/// No handler may run: a probe that reached one would file a report to find
/// out whether reports can be filed.
#[tokio::test]
async fn probing_does_not_reach_a_handler() {
    let reached = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let flag = reached.clone();
    let router = Router::new().route(
        "/reports",
        post(move || {
            let flag = flag.clone();
            async move {
                flag.store(true, std::sync::atomic::Ordering::SeqCst);
                "{}"
            }
        }),
    );
    assert!(served_by(router).await.contains(&Capability::Report));
    assert!(!reached.load(std::sync::atomic::Ordering::SeqCst));
}

/// `/version` uses the derivation, not a list written beside it.
///
/// Every negative test above drives `served_by` against a synthetic router;
/// this drives the exact function `/version` builds its list from
/// (`http::capability_names`) against two routers, so a hardcoded
/// `["block", "report"]` in that path could not answer differently for a bare
/// router than for one that serves both. The one-line `capabilities` wrapper
/// over `capability_names(router(state))` is then trivially the real router's
/// answer.
#[tokio::test]
async fn version_capability_names_are_derived_from_the_router() {
    let bare = Router::new().route("/healthz", get(|| async { "ok" }));
    assert!(
        http::capability_names(bare).await.is_empty(),
        "a router without the safety routes advertises nothing"
    );

    let full = Router::new()
        .route(
            "/blocks/{user_id}",
            post(|| async { StatusCode::NO_CONTENT }).delete(|| async { StatusCode::NO_CONTENT }),
        )
        .route("/reports", get(|| async { "[]" }).post(|| async { "{}" }));
    assert_eq!(
        http::capability_names(full).await,
        vec!["block", "report"],
        "a router with both serves both, by name"
    );
}
