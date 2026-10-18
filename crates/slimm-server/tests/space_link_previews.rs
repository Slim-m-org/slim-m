// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The space-wide link preview switch: the admin gate, what `/version` says,
//! and that the unfurl route honours it.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::http::link_preview::LinkPreviews;
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::Store;
use tower::ServiceExt;

mod support;
use support::overwrite_harness::{new_store, register, request};

fn app(store: Store, link_previews: LinkPreviews) -> Router {
    http::router(AppState {
        store,
        auth: Auth::new(2).unwrap(),
        hub: Hub::new(),
        limiter: RateLimiter::new(),
        push: PushSender::disabled(),
        voice: slimm_server::voice::VoiceService::disabled(),
        media: slimm_server::media::Media::for_tests(),
        gifs: slimm_server::http::gifs::GifSearch::disabled(),
        link_previews,
        dock: slimm_server::http::dock::Dock::disabled(),
        code_runner: slimm_server::code_runner::CodeRunner::disabled(),
    })
}

async fn call(
    router: &Router,
    method: &str,
    uri: &str,
    token: Option<&str>,
    body: Option<Value>,
) -> (StatusCode, Value) {
    let response = router
        .clone()
        .oneshot(request(method, uri, token, body))
        .await
        .unwrap();
    let status = response.status();
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    (
        status,
        serde_json::from_slice(&bytes).unwrap_or(Value::Null),
    )
}

#[tokio::test]
async fn an_admin_turns_previews_off_and_on_and_the_unfurl_route_follows() {
    let (store, _guard) = new_store("slimm-space-link-previews").await;
    let (admin, _) = register(&store, "root").await;
    let (member, _) = register(&store, "nia").await;
    let router = app(store.clone(), LinkPreviews::for_test());
    let unfurl = "/link-preview?url=https%3A%2F%2Fexample.com%2F";

    let (_, version) = call(&router, "GET", "/version", None, None).await;
    assert_eq!(version["link_previews_enabled"], true);

    let (status, _) = call(
        &router,
        "PATCH",
        "/space/link-previews",
        Some(&member),
        Some(json!({"enabled": false})),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);

    let (status, body) = call(
        &router,
        "PATCH",
        "/space/link-previews",
        Some(&admin),
        Some(json!({"enabled": false})),
    )
    .await;
    assert_eq!((status, &body["enabled"]), (StatusCode::OK, &json!(false)));
    let (_, version) = call(&router, "GET", "/version", None, None).await;
    assert_eq!(version["link_previews_enabled"], false);
    let (status, _) = call(&router, "GET", unfurl, Some(&member), None).await;
    assert_eq!(status, StatusCode::NOT_IMPLEMENTED);
    assert_eq!(store.link_previews_override().await.unwrap(), Some(false));

    call(
        &router,
        "PATCH",
        "/space/link-previews",
        Some(&admin),
        Some(json!({"enabled": true})),
    )
    .await;
    let (_, version) = call(&router, "GET", "/version", None, None).await;
    assert_eq!(version["link_previews_enabled"], true);
    let (status, _) = call(&router, "GET", unfurl, Some(&member), None).await;
    assert_ne!(status, StatusCode::NOT_IMPLEMENTED);
}

#[tokio::test]
async fn the_saved_choice_wins_over_the_operator_default_at_startup() {
    let previews = LinkPreviews::for_test();
    previews.set_override(Some(false));
    assert!(!previews.is_enabled());
    previews.set_override(None);
    assert!(previews.is_enabled(), "no choice follows the operator");
}

#[tokio::test]
async fn a_build_without_unfurling_cannot_be_switched_on() {
    let previews = LinkPreviews::disabled();
    previews.set_override(Some(true));
    assert!(!previews.is_enabled());
}
