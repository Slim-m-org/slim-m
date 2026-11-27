// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The access token a refresh replaced keeps working for a short grace, so a request in flight or
//! a second process on the session survives a rotation; every revocation still ends it at once.
//! Failed sign-ins and dead tokens also answer with a machine-readable `code`.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::store::RefreshOutcome;
use tower::ServiceExt;

use crate::support;
use crate::totp_support;
use totp_support::{PASSWORD, app, json_body, member, now_ms, request};

async fn get_me(app: &Router, token: &str) -> (StatusCode, Option<String>, Value) {
    let response = app
        .clone()
        .oneshot(request("GET", "/me", Some(token), None))
        .await
        .unwrap();
    let status = response.status();
    let challenge = response
        .headers()
        .get("www-authenticate")
        .map(|v| v.to_str().unwrap().to_owned());
    (status, challenge, json_body(response).await)
}

async fn status_of(app: &Router, token: &str) -> StatusCode {
    get_me(app, token).await.0
}

struct Rig {
    store: slimm_server::store::Store,
    pool: sqlx::SqlitePool,
    app: Router,
    user: slimm_server::ids::UserId,
    _guard: support::TestDbGuard,
}

async fn rig() -> Rig {
    let (store, pool, guard) = support::new_store_with_pool("slimm-token-grace").await;
    let auth = slimm_server::auth::Auth::new(2).unwrap();
    let (_token, id) = member(&store, &auth, "ada").await;
    Rig {
        app: app(store.clone(), auth),
        store,
        pool,
        user: slimm_server::ids::UserId(id.parse().unwrap()),
        _guard: guard,
    }
}

async fn rotate(
    store: &slimm_server::store::Store,
    refresh: &str,
) -> slimm_server::store::IssuedTokens {
    match store.rotate_refresh(refresh).await.unwrap() {
        RefreshOutcome::Rotated(tokens) => tokens,
        _ => panic!("expected a rotation"),
    }
}

fn hash_of(token: &str) -> String {
    use sha2::{Digest, Sha256};
    format!("{:x}", Sha256::digest(token.as_bytes()))
}

/// Moves a token's expiry to `ms` from now, so a test can age it without sleeping.
async fn expire_in(pool: &sqlx::SqlitePool, token: &str, ms: i64) {
    let hash = hash_of(token);
    let at = now_ms() + ms;
    sqlx::query("UPDATE access_tokens SET expires_at = ? WHERE token_hash = ?")
        .bind(at)
        .bind(hash)
        .execute(pool)
        .await
        .unwrap();
}

async fn expires_at(pool: &sqlx::SqlitePool, token: &str) -> i64 {
    let hash = hash_of(token);
    sqlx::query_scalar("SELECT expires_at FROM access_tokens WHERE token_hash = ?")
        .bind(hash)
        .fetch_one(pool)
        .await
        .unwrap()
}

#[tokio::test]
async fn the_token_a_refresh_replaced_still_works_for_the_grace() {
    let r = rig().await;
    let login = r.store.open_session(r.user, "agent").await.unwrap();
    let next = rotate(&r.store, &login.refresh_token).await;
    assert_eq!(status_of(&r.app, &login.access_token).await, StatusCode::OK);
    assert_eq!(status_of(&r.app, &next.access_token).await, StatusCode::OK);

    let left = expires_at(&r.pool, &login.access_token).await - now_ms();
    assert!(left <= 30_000, "grace must be at most 30s, was {left}ms");
}

#[tokio::test]
async fn the_grace_ends_after_thirty_seconds_and_says_expired() {
    let r = rig().await;
    let login = r.store.open_session(r.user, "agent").await.unwrap();
    rotate(&r.store, &login.refresh_token).await;
    expire_in(&r.pool, &login.access_token, -1).await;
    let (status, challenge, body) = get_me(&r.app, &login.access_token).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    assert_eq!(body["code"], "token_expired");
    assert_eq!(body["error"], "invalid credentials");
    assert_eq!(
        challenge.as_deref(),
        Some(r#"Bearer error="invalid_token""#)
    );
}

#[tokio::test]
async fn a_token_nearly_expired_keeps_its_own_earlier_expiry() {
    let r = rig().await;
    let login = r.store.open_session(r.user, "agent").await.unwrap();
    expire_in(&r.pool, &login.access_token, 5_000).await;
    let before = expires_at(&r.pool, &login.access_token).await;
    rotate(&r.store, &login.refresh_token).await;
    assert_eq!(expires_at(&r.pool, &login.access_token).await, before);
}

#[tokio::test]
async fn a_replayed_refresh_token_kills_the_grace_token_at_once() {
    let r = rig().await;
    let login = r.store.open_session(r.user, "agent").await.unwrap();
    let next = rotate(&r.store, &login.refresh_token).await;
    // Using the new access token confirms the rotation, retiring the first refresh token.
    assert_eq!(status_of(&r.app, &next.access_token).await, StatusCode::OK);
    assert!(matches!(
        r.store.rotate_refresh(&login.refresh_token).await.unwrap(),
        RefreshOutcome::Reused(_)
    ));
    assert_eq!(
        status_of(&r.app, &login.access_token).await,
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        status_of(&r.app, &next.access_token).await,
        StatusCode::UNAUTHORIZED
    );
}

#[tokio::test]
async fn signing_out_kills_the_grace_token_at_once() {
    let r = rig().await;
    let login = r.store.open_session(r.user, "agent").await.unwrap();
    let next = rotate(&r.store, &login.refresh_token).await;
    let response = r
        .app
        .clone()
        .oneshot(request(
            "POST",
            "/auth/logout",
            Some(&next.access_token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);
    let (status, _, body) = get_me(&r.app, &login.access_token).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    assert_eq!(body["code"], "token_invalid");
}

#[tokio::test]
async fn removing_the_device_kills_the_grace_token_at_once() {
    let r = rig().await;
    let login = r.store.open_session(r.user, "agent").await.unwrap();
    let admin = r.store.open_session(r.user, "laptop").await.unwrap();
    rotate(&r.store, &login.refresh_token).await;
    assert_eq!(status_of(&r.app, &login.access_token).await, StatusCode::OK);
    r.store
        .remove_device(r.user, login.device_id)
        .await
        .unwrap()
        .expect("device is the user's");
    assert_eq!(
        status_of(&r.app, &login.access_token).await,
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(status_of(&r.app, &admin.access_token).await, StatusCode::OK);
}

#[tokio::test]
async fn a_password_change_elsewhere_kills_the_grace_token_at_once() {
    let r = rig().await;
    let agent = r.store.open_session(r.user, "agent").await.unwrap();
    let laptop = r.store.open_session(r.user, "laptop").await.unwrap();
    rotate(&r.store, &agent.refresh_token).await;
    let response = r
        .app
        .clone()
        .oneshot(request(
            "POST",
            "/auth/password",
            Some(&laptop.access_token),
            Some(json!({"current_password": PASSWORD, "new_password": "a-brand-new-passphrase"})),
        ))
        .await
        .unwrap();
    assert!(response.status().is_success(), "{}", response.status());
    assert_eq!(
        status_of(&r.app, &agent.access_token).await,
        StatusCode::UNAUTHORIZED
    );
}

#[tokio::test]
async fn unknown_and_missing_tokens_and_wrong_passwords_are_told_apart() {
    let r = rig().await;
    let (status, challenge, body) = get_me(&r.app, "not-a-token").await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    assert_eq!(body["code"], "token_invalid");
    assert_eq!(
        challenge.as_deref(),
        Some(r#"Bearer error="invalid_token""#)
    );

    let response = r
        .app
        .clone()
        .oneshot(request(
            "POST",
            "/auth/login",
            None,
            Some(json!({"username": "ada", "password": "wrong-password-here", "device_name": "x"})),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    assert!(response.headers().get("www-authenticate").is_none());
    let body = json_body(response).await;
    assert_eq!(body["code"], "bad_credentials");
    assert_eq!(body["error"], "invalid credentials");
}

#[tokio::test]
async fn a_pending_token_rotating_again_leaves_no_grace_behind() {
    let r = rig().await;
    let login = r.store.open_session(r.user, "agent").await.unwrap();
    let first = rotate(&r.store, &login.refresh_token).await;
    let second = rotate(&r.store, &login.refresh_token).await;
    for stale in [&login.access_token, &first.access_token] {
        assert_eq!(status_of(&r.app, stale).await, StatusCode::UNAUTHORIZED);
    }
    assert_eq!(
        status_of(&r.app, &second.access_token).await,
        StatusCode::OK
    );
}
