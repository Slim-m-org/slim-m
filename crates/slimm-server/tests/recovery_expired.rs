// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! An expired reset code is as dead as an unknown one, and says so identically.
//!
//! Both the advisory check in the handler and the claim inside the consuming
//! transaction filter on `expires_at`; either alone would hide the other being
//! dropped, so each is pinned against the store directly as well.

use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::store::{ConsumeResetError, Store};
use tower::ServiceExt;

mod support;

use support::app::{app, json_body, request};

const PASSWORD: &str = "correct-horse-battery";
const NEW_PASSWORD: &str = "newhunter2newhunter2";

async fn register(store: &Store, username: &str) -> (String, String) {
    let hash = Auth::new(2)
        .unwrap()
        .hash_password(PASSWORD.to_owned())
        .await
        .unwrap();
    let account = store
        .create_account(username, username, &hash)
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    let tokens = store.open_session(account.id, "cli").await.unwrap();
    (tokens.access_token, account.id.to_string())
}

async fn reset(app: &axum::Router, code: &str) -> (StatusCode, Value) {
    let response = app
        .clone()
        .oneshot(request(
            "POST",
            "/auth/reset",
            None,
            Some(json!({ "code": code, "new_password": NEW_PASSWORD })),
        ))
        .await
        .unwrap();
    (response.status(), json_body(response).await)
}

async fn status_of(app: &axum::Router, method: &str, uri: &str, token: Option<&str>) -> StatusCode {
    app.clone()
        .oneshot(request(method, uri, token, None))
        .await
        .unwrap()
        .status()
}

async fn login(app: &axum::Router, password: &str) -> StatusCode {
    app.clone()
        .oneshot(request(
            "POST",
            "/auth/login",
            None,
            Some(json!({ "username": "bob", "password": password, "device_name": "cli" })),
        ))
        .await
        .unwrap()
        .status()
}

#[tokio::test]
async fn an_expired_code_is_refused_like_an_unknown_one_and_changes_nothing() {
    let (store, pool, _guard) = support::new_store_with_pool("slimm-recovery-expired").await;
    let app = app(store.clone());
    let (admin_token, _admin_id) = register(&store, "alice").await;
    let (bob_token, bob_id) = register(&store, "bob").await;
    let issued = app
        .clone()
        .oneshot(request(
            "POST",
            &format!("/admin/users/{bob_id}/reset-code"),
            Some(&admin_token),
            Some(json!({ "password": PASSWORD })),
        ))
        .await
        .unwrap();
    assert_eq!(issued.status(), StatusCode::OK);
    let code = json_body(issued).await["code"].as_str().unwrap().to_owned();
    sqlx::query("UPDATE password_reset_codes SET expires_at = 1")
        .execute(&pool)
        .await
        .unwrap();

    let expired = reset(&app, &code).await;
    let unknown = reset(&app, "a-code-nobody-issued").await;

    assert_eq!(expired.0, StatusCode::BAD_REQUEST);
    assert_eq!(
        expired, unknown,
        "an expired code must not be told apart from an unknown one"
    );
    assert_eq!(
        status_of(&app, "GET", "/me", Some(&bob_token)).await,
        StatusCode::OK
    );
    assert_eq!(
        login(&app, PASSWORD).await,
        StatusCode::OK,
        "the password must be unchanged"
    );
    assert_eq!(login(&app, NEW_PASSWORD).await, StatusCode::UNAUTHORIZED);

    assert!(!store.reset_code_is_live(&code).await.unwrap());
    let consumed = store.consume_reset_code(&code, "not-a-real-hash").await;
    assert!(matches!(consumed, Err(ConsumeResetError::Unusable)));
    assert_eq!(
        status_of(&app, "GET", "/me", Some(&bob_token)).await,
        StatusCode::OK
    );
}
