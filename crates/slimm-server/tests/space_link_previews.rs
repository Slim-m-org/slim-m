// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The space-wide link preview switch: the admin gate, what `/version` says,
//! and that the unfurl route honours it.

use axum::Router;
use axum::http::StatusCode;
use serde_json::json;
use slimm_server::http::link_preview::LinkPreviews;
use slimm_server::store::Store;

mod support;

use support::app::call;
use support::overwrite_harness::{new_store, register};

fn app(store: Store, link_previews: LinkPreviews) -> Router {
    support::app::builder(store)
        .link_previews(link_previews)
        .router()
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

#[tokio::test]
async fn an_admin_cannot_turn_previews_on_past_the_operator() {
    let previews = LinkPreviews::new(&slimm_server::config::Config::default(), [1; 32]);
    previews.set_override(Some(true));
    assert!(
        !previews.is_enabled(),
        "the operator left SLIMM_LINK_PREVIEWS off"
    );
}
