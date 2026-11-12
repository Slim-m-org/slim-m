// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Usernames are unique case-insensitively (migration 0095), and login finds
//! the one account a differently-cased name refers to.
#![allow(dead_code)]

use axum::http::StatusCode;
use serde_json::json;
use tower::ServiceExt;

use crate::totp_support;
use totp_support::{PASSWORD, app, json_body, member, new_store, request};

async fn invite(app: &axum::Router, token: &str) -> String {
    let created = app
        .clone()
        .oneshot(request("POST", "/invites", Some(token), Some(json!({}))))
        .await
        .unwrap();
    assert_eq!(created.status(), StatusCode::OK);
    json_body(created).await["code"]
        .as_str()
        .unwrap()
        .to_owned()
}

async fn register(app: &axum::Router, name: &str, code: &str) -> StatusCode {
    app.clone()
        .oneshot(request(
            "POST",
            "/auth/register",
            None,
            Some(json!({
                "username": name,
                "display_name": name,
                "password": PASSWORD,
                "device_name": "phone",
                "invite_code": code,
            })),
        ))
        .await
        .unwrap()
        .status()
}

async fn login_as(app: &axum::Router, name: &str, password: &str) -> axum::response::Response {
    app.clone()
        .oneshot(request(
            "POST",
            "/auth/login",
            None,
            Some(json!({ "username": name, "password": password, "device_name": "phone" })),
        ))
        .await
        .unwrap()
}

#[tokio::test]
async fn registering_a_name_that_differs_only_by_case_is_a_409() {
    let (store, auth, _guard) = new_store("slimm-username-case-register").await;
    let app = app(store.clone(), auth.clone());
    let (token, _id) = member(&store, &auth, "alice").await;
    let code = invite(&app, &token).await;

    assert_eq!(register(&app, "alice", &code).await, StatusCode::CONFLICT);
    assert_eq!(register(&app, "Alice", &code).await, StatusCode::CONFLICT);
    assert_eq!(register(&app, "ALICE", &code).await, StatusCode::CONFLICT);
    assert_eq!(register(&app, "alicia", &code).await, StatusCode::OK);
}

#[tokio::test]
async fn a_deleted_accounts_name_is_free_in_every_case() {
    let (store, auth, _guard) = new_store("slimm-username-case-free").await;
    let app = app(store.clone(), auth.clone());
    let (admin, _) = member(&store, &auth, "root").await;
    let hash = auth.hash_password(PASSWORD.to_owned()).await.unwrap();
    let ada = store.create_account("ada", "ada", &hash).await.unwrap();
    let token = store
        .open_session(ada.id, "cli")
        .await
        .unwrap()
        .access_token;
    let deleted = app
        .clone()
        .oneshot(request(
            "DELETE",
            "/account",
            Some(&token),
            Some(json!({ "password": PASSWORD })),
        ))
        .await
        .unwrap();
    assert_eq!(deleted.status(), StatusCode::NO_CONTENT);

    let code = invite(&app, &admin).await;
    assert_eq!(register(&app, "ADA", &code).await, StatusCode::OK);
}

/// Decided: login ignores case. The unique index makes the match unambiguous,
/// and a phone keyboard capitalising the first letter should not be a 401.
#[tokio::test]
async fn login_matches_the_username_in_any_case_and_still_checks_the_password() {
    let (store, auth, _guard) = new_store("slimm-username-case-login").await;
    let app = app(store.clone(), auth.clone());
    let (_token, id) = member(&store, &auth, "alice").await;

    for name in ["alice", "Alice", "ALICE"] {
        let response = login_as(&app, name, PASSWORD).await;
        assert_eq!(response.status(), StatusCode::OK, "{name}");
        assert_eq!(json_body(response).await["user_id"], json!(id));
    }
    let wrong = login_as(&app, "Alice", "wrong-password-here").await;
    assert_eq!(wrong.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn a_bot_cannot_take_a_members_name_in_another_case() {
    let (store, auth, _guard) = new_store("slimm-username-case-bot").await;
    let app = app(store.clone(), auth.clone());
    let (token, _id) = member(&store, &auth, "alice").await;

    let response = app
        .clone()
        .oneshot(request(
            "POST",
            "/bots",
            Some(&token),
            Some(json!({ "username": "Alice" })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::CONFLICT);
}

/// Every way a login can fail before the password is compared answers the same
/// 401, so the error never teaches the password policy or the username rules.
#[tokio::test]
async fn a_login_that_could_never_succeed_fails_like_a_wrong_password() {
    let (store, auth, _guard) = new_store("slimm-login-uniform").await;
    let app = app(store.clone(), auth.clone());
    member(&store, &auth, "alice").await;

    let wrong = login_as(&app, "alice", "wrong-password-here").await;
    let short = login_as(&app, "alice", "abc").await;
    let long = login_as(&app, "alice", &"x".repeat(2000)).await;
    let odd_name = login_as(&app, "not a name!", PASSWORD).await;
    let unknown = login_as(&app, "zed", "wrong-password-here").await;
    let bodies = [wrong, short, long, odd_name, unknown];
    let mut seen = Vec::new();
    for response in bodies {
        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
        seen.push(json_body(response).await);
    }
    assert!(seen.windows(2).all(|pair| pair[0] == pair[1]), "{seen:?}");
}
