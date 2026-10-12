// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Changing your own password: it needs the current one (and the current
//! two-factor code when that is on), signs every other device out, and leaves
//! the session that made the change signed in.
#![allow(dead_code)]

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use tower::ServiceExt;

mod support;
mod totp_support;

use totp_support::{PASSWORD, app, enrol_and_confirm, member, new_store, now_ms, request};

const NEW_PASSWORD: &str = "a-brand-new-passphrase";

async fn change(app: &Router, token: &str, body: Value) -> StatusCode {
    app.clone()
        .oneshot(request("POST", "/auth/password", Some(token), Some(body)))
        .await
        .unwrap()
        .status()
}

async fn login_with(app: &Router, username: &str, password: &str) -> StatusCode {
    app.clone()
        .oneshot(request(
            "POST",
            "/auth/login",
            None,
            Some(json!({
                "username": username,
                "password": password,
                "device_name": "phone",
            })),
        ))
        .await
        .unwrap()
        .status()
}

async fn whoami(app: &Router, token: &str) -> StatusCode {
    app.clone()
        .oneshot(request("GET", "/me", Some(token), None))
        .await
        .unwrap()
        .status()
}

#[tokio::test]
async fn a_wrong_current_password_is_refused_and_changes_nothing() {
    let (store, auth, _guard) = new_store("slimm-pwchange-wrong").await;
    let app = app(store.clone(), auth.clone());
    let (token, id) = member(&store, &auth, "ada").await;
    let other = store
        .open_session(slimm_server::ids::UserId(id.parse().unwrap()), "tablet")
        .await
        .unwrap()
        .access_token;

    let status = change(
        &app,
        &token,
        json!({ "current_password": "not-the-password", "new_password": NEW_PASSWORD }),
    )
    .await;

    assert_eq!(status, StatusCode::FORBIDDEN);
    assert_eq!(login_with(&app, "ada", PASSWORD).await, StatusCode::OK);
    assert_eq!(
        login_with(&app, "ada", NEW_PASSWORD).await,
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(whoami(&app, &other).await, StatusCode::OK);
}

#[tokio::test]
async fn a_missing_current_password_is_refused() {
    let (store, auth, _guard) = new_store("slimm-pwchange-missing").await;
    let app = app(store.clone(), auth.clone());
    let (token, _id) = member(&store, &auth, "ada").await;

    let status = change(&app, &token, json!({ "new_password": NEW_PASSWORD })).await;

    assert!(
        status.is_client_error(),
        "a bare token changed it: {status}"
    );
    assert_eq!(login_with(&app, "ada", PASSWORD).await, StatusCode::OK);
}

#[tokio::test]
async fn a_too_short_new_password_is_refused_with_the_signup_rule() {
    let (store, auth, _guard) = new_store("slimm-pwchange-short").await;
    let app = app(store.clone(), auth.clone());
    let (token, _id) = member(&store, &auth, "ada").await;

    let status = change(
        &app,
        &token,
        json!({ "current_password": PASSWORD, "new_password": "short" }),
    )
    .await;

    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(login_with(&app, "ada", PASSWORD).await, StatusCode::OK);
}

#[tokio::test]
async fn the_right_password_changes_it_and_signs_out_the_other_devices() {
    let (store, auth, _guard) = new_store("slimm-pwchange-ok").await;
    let app = app(store.clone(), auth.clone());
    let (token, id) = member(&store, &auth, "ada").await;
    let other = store
        .open_session(slimm_server::ids::UserId(id.parse().unwrap()), "tablet")
        .await
        .unwrap()
        .access_token;

    let status = change(
        &app,
        &token,
        json!({ "current_password": PASSWORD, "new_password": NEW_PASSWORD }),
    )
    .await;

    assert_eq!(status, StatusCode::NO_CONTENT);
    assert_eq!(
        login_with(&app, "ada", PASSWORD).await,
        StatusCode::UNAUTHORIZED,
        "the old password still works"
    );
    assert_eq!(login_with(&app, "ada", NEW_PASSWORD).await, StatusCode::OK);
    assert_eq!(
        whoami(&app, &token).await,
        StatusCode::OK,
        "this session ended"
    );
    assert_eq!(
        whoami(&app, &other).await,
        StatusCode::UNAUTHORIZED,
        "another device stayed signed in"
    );
}

#[tokio::test]
async fn two_factor_on_requires_the_current_code() {
    let (store, auth, _guard) = new_store("slimm-pwchange-totp").await;
    let app = app(store.clone(), auth.clone());
    let (token, _id) = member(&store, &auth, "ada").await;
    let (secret, _codes) = enrol_and_confirm(&app, &token).await;

    let without = change(
        &app,
        &token,
        json!({ "current_password": PASSWORD, "new_password": NEW_PASSWORD }),
    )
    .await;
    assert!(
        without.is_client_error(),
        "changed without a code: {without}"
    );

    let wrong = change(
        &app,
        &token,
        json!({
            "current_password": PASSWORD,
            "new_password": NEW_PASSWORD,
            "code": "000000",
        }),
    )
    .await;
    assert!(
        wrong.is_client_error(),
        "changed with a wrong code: {wrong}"
    );
    assert_eq!(
        login_with(&app, "ada", NEW_PASSWORD).await,
        StatusCode::UNAUTHORIZED
    );

    let code = slimm_server::totp::code_at(&secret, now_ms()).unwrap();
    let right = change(
        &app,
        &token,
        json!({
            "current_password": PASSWORD,
            "new_password": NEW_PASSWORD,
            "code": code,
        }),
    )
    .await;
    assert_eq!(right, StatusCode::NO_CONTENT);
    assert_eq!(
        login_with(&app, "ada", PASSWORD).await,
        StatusCode::UNAUTHORIZED
    );
}
