// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `POST /auth/username/check` answers whether a live account holds a name,
//! the way registration decides it, without hashing or writing anything.
#![allow(dead_code)]

use axum::http::StatusCode;
use serde_json::json;
use tower::ServiceExt;

use crate::totp_support;
use totp_support::{PASSWORD, app, json_body, member, new_store, request};

async fn check(app: &axum::Router, name: &str) -> (StatusCode, serde_json::Value) {
    let response = app
        .clone()
        .oneshot(request(
            "POST",
            "/auth/username/check",
            None,
            Some(json!({ "username": name })),
        ))
        .await
        .unwrap();
    let status = response.status();
    (status, json_body(response).await)
}

async fn exists(app: &axum::Router, name: &str) -> bool {
    let (status, body) = check(app, name).await;
    assert_eq!(status, StatusCode::OK, "{name}");
    body["exists"].as_bool().expect("exists is a bool")
}

#[tokio::test]
async fn an_unknown_name_does_not_exist_and_a_registered_one_does_in_any_case() {
    let (store, auth, _guard) = new_store("slimm-username-check-basic").await;
    let app = app(store.clone(), auth.clone());

    assert!(!exists(&app, "alice").await);
    member(&store, &auth, "alice").await;
    assert!(exists(&app, "alice").await);
    assert!(exists(&app, "Alice").await);
    assert!(exists(&app, "ALICE").await);
    assert!(!exists(&app, "alicia").await);
}

#[tokio::test]
async fn a_deleted_accounts_name_does_not_exist() {
    let (store, auth, _guard) = new_store("slimm-username-check-deleted").await;
    let app = app(store.clone(), auth.clone());
    let (_token, _id) = member(&store, &auth, "root").await;
    let hash = auth.hash_password(PASSWORD.to_owned()).await.unwrap();
    let ada = store.create_account("ada", "ada", &hash).await.unwrap();
    assert!(exists(&app, "ada").await);

    store.delete_account(ada.id).await.unwrap();
    assert!(!exists(&app, "ada").await);
}

#[tokio::test]
async fn a_bot_name_exists() {
    let (store, auth, _guard) = new_store("slimm-username-check-bot").await;
    let app = app(store.clone(), auth.clone());
    let (token, _id) = member(&store, &auth, "alice").await;
    let created = app
        .clone()
        .oneshot(request(
            "POST",
            "/bots",
            Some(&token),
            Some(json!({ "username": "helper" })),
        ))
        .await
        .unwrap();
    assert_eq!(created.status(), StatusCode::CREATED);

    assert!(exists(&app, "Helper").await);
}

#[tokio::test]
async fn an_invalid_username_is_a_400_like_registration() {
    let (store, auth, _guard) = new_store("slimm-username-check-invalid").await;
    let app = app(store, auth);

    for name in ["", "has space", "everyone", &"x".repeat(33)] {
        let (status, _) = check(&app, name).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{name:?}");
    }
}

#[tokio::test]
async fn the_check_is_rate_limited_but_leaves_the_password_budget_alone() {
    let (store, auth, _guard) = new_store("slimm-username-check-limit").await;
    let app = app(store, auth);

    let mut refused = false;
    for _ in 0..40 {
        if check(&app, "nobody").await.0 == StatusCode::TOO_MANY_REQUESTS {
            refused = true;
            break;
        }
    }
    assert!(refused, "a sustained flood is refused");

    let login = app
        .clone()
        .oneshot(request(
            "POST",
            "/auth/login",
            None,
            Some(json!({ "username": "nobody", "password": PASSWORD, "device_name": "cli" })),
        ))
        .await
        .unwrap();
    assert_eq!(login.status(), StatusCode::UNAUTHORIZED);
}
