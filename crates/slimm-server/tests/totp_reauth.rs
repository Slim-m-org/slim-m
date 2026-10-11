// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A session token alone must not turn two-factor on or delete an account
//! (decision 0048, "Proof to change a security control").
#![allow(dead_code)]

use axum::http::StatusCode;
use serde_json::{Value, json};
use tower::ServiceExt;

mod support;
mod totp_support;

use totp_support::{
    PASSWORD, STEP_MS, app, begin_enrolment, enrol_and_confirm, json_body, login, member,
    new_store, now_ms, request,
};

async fn status_of(
    app: &axum::Router,
    method: &str,
    uri: &str,
    token: &str,
    body: Option<Value>,
) -> StatusCode {
    app.clone()
        .oneshot(request(method, uri, Some(token), body))
        .await
        .unwrap()
        .status()
}

#[tokio::test]
async fn enrolment_needs_the_password_not_just_a_token() {
    let (store, auth, _guard) = new_store("slimm-reauth-enrol").await;
    let app = app(store.clone(), auth.clone());
    let (token, _id) = member(&store, &auth, "ada").await;

    let bare = status_of(&app, "POST", "/auth/totp/enrol", &token, None).await;
    assert!(bare.is_client_error(), "a bare token enrolled: {bare}");
    let wrong = status_of(
        &app,
        "POST",
        "/auth/totp/enrol",
        &token,
        Some(json!({ "password": "not-the-password" })),
    )
    .await;
    assert_eq!(wrong, StatusCode::FORBIDDEN);
    let status = json_body(
        app.clone()
            .oneshot(request("GET", "/auth/totp", Some(&token), None))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(
        status["pending"],
        json!(false),
        "a refused enrol left state"
    );
}

#[tokio::test]
async fn confirming_needs_the_password_not_just_a_token_and_a_code() {
    let (store, auth, _guard) = new_store("slimm-reauth-confirm").await;
    let app = app(store.clone(), auth.clone());
    let (token, _id) = member(&store, &auth, "ada").await;
    let secret = begin_enrolment(&app, &token).await;
    let code = slimm_server::totp::code_at(&secret, now_ms() - STEP_MS).unwrap();

    let bare = status_of(
        &app,
        "POST",
        "/auth/totp/confirm",
        &token,
        Some(json!({ "code": code })),
    )
    .await;
    assert!(bare.is_client_error(), "a token and code confirmed: {bare}");
    let wrong = status_of(
        &app,
        "POST",
        "/auth/totp/confirm",
        &token,
        Some(json!({ "code": code, "password": "not-the-password" })),
    )
    .await;
    assert_eq!(wrong, StatusCode::FORBIDDEN);
    assert_eq!(login(&app, "ada").await.status(), StatusCode::OK);
}

#[tokio::test]
async fn deleting_an_account_needs_the_password() {
    let (store, auth, _guard) = new_store("slimm-reauth-delete").await;
    let app = app(store.clone(), auth.clone());
    let (_admin, _) = member(&store, &auth, "root").await;
    let hash = auth.hash_password(PASSWORD.to_owned()).await.unwrap();
    let account = store.create_account("ada", "ada", &hash).await.unwrap();
    let token = store
        .open_session(account.id, "cli")
        .await
        .unwrap()
        .access_token;

    let bare = status_of(&app, "DELETE", "/account", &token, None).await;
    assert!(bare.is_client_error(), "a bare token deleted: {bare}");
    let wrong = status_of(
        &app,
        "DELETE",
        "/account",
        &token,
        Some(json!({ "password": "nope-nope-nope" })),
    )
    .await;
    assert_eq!(wrong, StatusCode::FORBIDDEN);
    assert_eq!(
        login(&app, "ada").await.status(),
        StatusCode::OK,
        "account survived"
    );

    let ok = status_of(
        &app,
        "DELETE",
        "/account",
        &token,
        Some(json!({ "password": PASSWORD })),
    )
    .await;
    assert_eq!(ok, StatusCode::NO_CONTENT);
}

#[tokio::test]
async fn deleting_an_account_with_a_factor_also_needs_a_current_code() {
    let (store, auth, _guard) = new_store("slimm-reauth-delete-2fa").await;
    let app = app(store.clone(), auth.clone());
    let (_admin, _) = member(&store, &auth, "root").await;
    let hash = auth.hash_password(PASSWORD.to_owned()).await.unwrap();
    let account = store.create_account("ada", "ada", &hash).await.unwrap();
    let token = store
        .open_session(account.id, "cli")
        .await
        .unwrap()
        .access_token;
    let (secret, _codes) = enrol_and_confirm(&app, &token).await;

    let password_only = status_of(
        &app,
        "DELETE",
        "/account",
        &token,
        Some(json!({ "password": PASSWORD })),
    )
    .await;
    assert_eq!(password_only, StatusCode::BAD_REQUEST);
    let wrong_code = status_of(
        &app,
        "DELETE",
        "/account",
        &token,
        Some(json!({ "password": PASSWORD, "code": "000000" })),
    )
    .await;
    assert_eq!(wrong_code, StatusCode::BAD_REQUEST);

    let code = slimm_server::totp::code_at(&secret, now_ms()).unwrap();
    let ok = status_of(
        &app,
        "DELETE",
        "/account",
        &token,
        Some(json!({ "password": PASSWORD, "code": code })),
    )
    .await;
    assert_eq!(ok, StatusCode::NO_CONTENT);
}

#[tokio::test]
async fn a_well_formed_request_without_a_password_is_a_400() {
    let (store, auth, _guard) = new_store("slimm-reauth-missing").await;
    let app = app(store.clone(), auth.clone());
    let (token, _id) = member(&store, &auth, "ada").await;

    for (method, uri, body) in [
        ("POST", "/auth/totp/enrol", json!({})),
        ("POST", "/auth/totp/confirm", json!({ "code": "123456" })),
        ("DELETE", "/account", json!({})),
    ] {
        let status = status_of(&app, method, uri, &token, Some(body)).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{method} {uri}");
    }
}

#[tokio::test]
async fn an_administrator_issuing_a_reset_code_needs_their_own_password() {
    let (store, auth, _guard) = new_store("slimm-reauth-admin-reset").await;
    let app = app(store.clone(), auth.clone());
    let (admin, _) = member(&store, &auth, "root").await;
    let hash = auth.hash_password(PASSWORD.to_owned()).await.unwrap();
    let bob = store.create_account("bob", "bob", &hash).await.unwrap();
    let uri = format!("/admin/users/{}/reset-code", bob.id);

    let bare = status_of(&app, "POST", &uri, &admin, None).await;
    assert_eq!(bare, StatusCode::BAD_REQUEST, "a bare token issued a code");
    let wrong = status_of(
        &app,
        "POST",
        &uri,
        &admin,
        Some(json!({ "password": "nope-nope" })),
    )
    .await;
    assert_eq!(wrong, StatusCode::FORBIDDEN);
    let ok = status_of(
        &app,
        "POST",
        &uri,
        &admin,
        Some(json!({ "password": PASSWORD })),
    )
    .await;
    assert_eq!(ok, StatusCode::OK);
}

#[tokio::test]
async fn an_administrator_clearing_two_factor_needs_their_own_password() {
    let (store, auth, _guard) = new_store("slimm-reauth-admin-clear").await;
    let app = app(store.clone(), auth.clone());
    let (admin, _) = member(&store, &auth, "root").await;
    let hash = auth.hash_password(PASSWORD.to_owned()).await.unwrap();
    let bob = store.create_account("bob", "bob", &hash).await.unwrap();
    let bob_token = store
        .open_session(bob.id, "cli")
        .await
        .unwrap()
        .access_token;
    enrol_and_confirm(&app, &bob_token).await;
    let uri = format!("/admin/users/{}/totp", bob.id);

    let bare = status_of(&app, "DELETE", &uri, &admin, None).await;
    assert_eq!(
        bare,
        StatusCode::BAD_REQUEST,
        "a bare token cleared a factor"
    );
    let wrong = status_of(
        &app,
        "DELETE",
        &uri,
        &admin,
        Some(json!({ "password": "nope-nope" })),
    )
    .await;
    assert_eq!(wrong, StatusCode::FORBIDDEN);
    let still_on = json_body(
        app.clone()
            .oneshot(request("GET", "/auth/totp", Some(&bob_token), None))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(
        still_on["enabled"],
        json!(true),
        "a refused clear removed the factor"
    );

    let ok = status_of(
        &app,
        "DELETE",
        &uri,
        &admin,
        Some(json!({ "password": PASSWORD })),
    )
    .await;
    assert_eq!(ok, StatusCode::NO_CONTENT);
}
