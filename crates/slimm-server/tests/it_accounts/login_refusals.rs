// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What sign-in says when it refuses: a removed member is told why, and a
//! malformed password is an ordinary wrong password rather than a hint at the
//! password policy.
#![allow(dead_code)]

use axum::http::StatusCode;
use serde_json::json;
use tower::ServiceExt;

use crate::totp_support;
use totp_support::{PASSWORD, app, json_body, member, new_store, request};

async fn login_with(router: &axum::Router, username: &str, password: &str) -> (StatusCode, String) {
    let response = router
        .clone()
        .oneshot(request(
            "POST",
            "/auth/login",
            None,
            Some(json!({ "username": username, "password": password, "device_name": "cli" })),
        ))
        .await
        .unwrap();
    let status = response.status();
    let body = json_body(response).await;
    (
        status,
        body["error"].as_str().unwrap_or_default().to_owned(),
    )
}

#[tokio::test]
async fn a_removed_member_is_told_they_were_removed() {
    let (store, auth, _guard) = new_store("slimm-login-removed").await;
    let router = app(store.clone(), auth.clone());
    let (admin_token, _) = member(&store, &auth, "alice").await;
    let hash = auth.hash_password(PASSWORD.to_owned()).await.unwrap();
    let bob = store.create_account("bob", "bob", &hash).await.unwrap();

    let removal = router
        .clone()
        .oneshot(request(
            "PUT",
            &format!("/members/{}/removal", bob.id),
            Some(&admin_token),
            Some(json!({})),
        ))
        .await
        .unwrap();
    assert_eq!(removal.status(), StatusCode::NO_CONTENT);

    let (status, error) = login_with(&router, "bob", PASSWORD).await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert_eq!(error, "you have been removed from this server");
}

#[tokio::test]
async fn a_too_short_password_is_a_wrong_password_not_a_policy_hint() {
    let (store, auth, _guard) = new_store("slimm-login-short-password").await;
    let router = app(store.clone(), auth.clone());
    member(&store, &auth, "alice").await;

    let (status, error) = login_with(&router, "alice", "abc").await;
    let (wrong_status, wrong_error) = login_with(&router, "alice", "a-wrong-password").await;
    assert_eq!((status, error), (wrong_status, wrong_error));
    assert_eq!(status, StatusCode::UNAUTHORIZED);
}
