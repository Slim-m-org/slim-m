// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Text columns that hold a closed set of words have no CHECK in the schema,
//! so the route in front of each is the only guard. These pin that guard:
//! a value outside the set is a 400 and nothing is written.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::store::Store;
use tower::ServiceExt;
use uuid::Uuid;

mod support;
use support::overwrite_harness::{
    app, general_channel_id, json_body, new_store, register, request,
};

async fn call(
    router: &Router,
    method: &str,
    uri: &str,
    token: &str,
    body: Value,
) -> (StatusCode, String) {
    let response = router
        .clone()
        .oneshot(request(method, uri, Some(token), Some(body)))
        .await
        .unwrap();
    let status = response.status();
    let body = json_body(response).await;
    (
        status,
        body["error"].as_str().unwrap_or_default().to_owned(),
    )
}

async fn world() -> (Store, Router, String, support::TestDbGuard) {
    let (store, guard) = new_store("slimm-enum-columns").await;
    let router = app(store.clone());
    let (token, _) = register(&store, "alice").await;
    (store, router, token, guard)
}

#[tokio::test]
async fn a_category_overwrite_target_must_be_role_or_member() {
    let (_store, router, token, _guard) = world().await;
    let created = router
        .clone()
        .oneshot(request(
            "POST",
            "/categories",
            Some(&token),
            Some(json!({"name": "ops"})),
        ))
        .await
        .unwrap();
    let category = json_body(created).await["id"].as_str().unwrap().to_owned();
    let body = json!({"overwrites": [{"kind": "bogus", "id": Uuid::now_v7().to_string(), "allow": 0, "deny": 0}]});
    let (status, error) = call(
        &router,
        "PUT",
        &format!("/categories/{category}/overwrites"),
        &token,
        body,
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "{error}");
    assert!(error.contains("kind must be role or member"), "{error}");
}

#[tokio::test]
async fn a_channel_overwrite_batch_target_must_be_role_or_member() {
    let (store, router, token, _guard) = world().await;
    let channel = general_channel_id(&store).await;
    let body = json!({"overwrites": [{"kind": "bogus", "id": Uuid::now_v7().to_string(), "allow": 0, "deny": 0}]});
    let (status, error) = call(
        &router,
        "PUT",
        &format!("/channels/{channel}/overwrites"),
        &token,
        body,
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "{error}");
    assert!(error.contains("kind must be role or member"), "{error}");
}

#[tokio::test]
async fn a_report_subject_kind_must_be_one_the_server_knows() {
    let (_store, router, token, _guard) = world().await;
    let body =
        json!({"subject_kind": "channel", "subject_id": Uuid::now_v7().to_string(), "reason": "x"});
    let (status, error) = call(&router, "POST", "/reports", &token, body).await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "{error}");
    assert!(
        error.contains("subject_kind must be message, user or ephemeral_message"),
        "{error}"
    );
}

#[tokio::test]
async fn a_report_resolution_must_be_resolved_or_dismissed() {
    let (_store, router, token, _guard) = world().await;
    let uri = format!("/reports/{}", Uuid::now_v7());
    let (status, error) = call(
        &router,
        "PATCH",
        &uri,
        &token,
        json!({"resolution": "ignored"}),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "{error}");
    assert!(
        error.contains("resolution must be resolved or dismissed"),
        "{error}"
    );
}

#[tokio::test]
async fn a_push_platform_must_be_ios_or_android() {
    let (_store, router, token, _guard) = world().await;
    let body = json!({"platform": "windows", "push_token": "abcdefgh", "push_public_key": ""});
    let (status, error) = call(&router, "PUT", "/push", &token, body).await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "{error}");
    assert!(error.contains("platform must be ios or android"), "{error}");
}
