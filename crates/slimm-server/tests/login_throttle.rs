// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A guesser who rotates addresses is slowed per account, and the owner is never locked out
//! for good.
#![allow(dead_code)]

use axum::Router;
use axum::http::StatusCode;
use serde_json::json;
use slimm_server::auth::Auth;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::{FORGET_AFTER_MS, FREE_FAILURES, MAX_DELAY_MS, Store};
use tower::ServiceExt;

mod support;
mod totp_support;

use totp_support::{PASSWORD, json_body, member, new_store, request};

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
}

/// Trusts one proxy hop so each request can arrive from a different address.
fn app(store: Store, auth: Auth) -> Router {
    support::app::builder(store)
        .auth(auth)
        .limiter(RateLimiter::with_trusted_hops(1))
        .router()
}

async fn login_from(
    router: &Router,
    ip: usize,
    username: &str,
    password: &str,
) -> (StatusCode, String) {
    let mut req = request(
        "POST",
        "/auth/login",
        None,
        Some(json!({ "username": username, "password": password, "device_name": "cli" })),
    );
    req.headers_mut().insert(
        "x-forwarded-for",
        format!("198.51.100.{}", ip % 250 + 1).parse().unwrap(),
    );
    let response = router.clone().oneshot(req).await.unwrap();
    let status = response.status();
    let body = json_body(response).await;
    (
        status,
        body["error"].as_str().unwrap_or_default().to_owned(),
    )
}

#[tokio::test]
async fn guesses_from_rotating_addresses_are_throttled_per_account() {
    let (store, auth, _guard) = new_store("slimm-login-throttle").await;
    let router = app(store.clone(), auth.clone());
    member(&store, &auth, "alice").await;

    for i in 0..=FREE_FAILURES as usize {
        let (status, _) = login_from(&router, i, "alice", "wrong-password-1").await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
    }
    // The eleventh failure armed the throttle, so even the right password is a plain 401.
    let (wrong_status, wrong_error) = login_from(&router, 50, "alice", "wrong-password-2").await;
    let (status, error) = login_from(&router, 51, "alice", PASSWORD).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    assert_eq!((status, error), (wrong_status, wrong_error));
}

#[tokio::test]
async fn an_unknown_username_answers_like_a_throttled_account() {
    let (store, auth, _guard) = new_store("slimm-login-throttle-unknown").await;
    let router = app(store.clone(), auth.clone());
    member(&store, &auth, "alice").await;
    for i in 0..=FREE_FAILURES as usize {
        login_from(&router, i, "alice", "wrong-password-1").await;
    }
    let throttled = login_from(&router, 60, "alice", PASSWORD).await;
    let unknown = login_from(&router, 61, "nobody", PASSWORD).await;
    assert_eq!(throttled, unknown);
}

#[tokio::test]
async fn the_owner_signs_in_again_once_the_delay_passes_and_the_count_resets() {
    let (store, auth, _guard) = new_store("slimm-login-throttle-recover").await;
    let router = app(store.clone(), auth.clone());
    member(&store, &auth, "alice").await;
    let alice = store
        .live_user_id_by_username("alice")
        .await
        .unwrap()
        .unwrap();

    // An attacker hammering far past the free budget still only ever earns the capped delay.
    let start = now_ms() - MAX_DELAY_MS - 10_000;
    for i in 0..100 {
        store
            .record_login_failure_at(alice, start + i)
            .await
            .unwrap();
    }
    assert!(store.login_throttled_at(alice, start + 100).await.unwrap());
    assert!(
        !store
            .login_throttled_at(alice, start + 100 + MAX_DELAY_MS + 1)
            .await
            .unwrap(),
        "the delay is bounded"
    );

    let (status, _) = login_from(&router, 1, "alice", PASSWORD).await;
    assert_eq!(
        status,
        StatusCode::OK,
        "the right password works after the delay"
    );

    // The success cleared the count, so the next wrong guesses start from zero.
    for i in 0..FREE_FAILURES as usize {
        login_from(&router, i, "alice", "wrong-password-1").await;
    }
    let (status, _) = login_from(&router, 99, "alice", PASSWORD).await;
    assert_eq!(status, StatusCode::OK);
}

#[tokio::test]
async fn a_quiet_spell_forgets_the_failures() {
    let (store, auth, _guard) = new_store("slimm-login-throttle-forget").await;
    member(&store, &auth, "alice").await;
    let alice = store
        .live_user_id_by_username("alice")
        .await
        .unwrap()
        .unwrap();
    let start = now_ms();
    for i in 0..30 {
        store
            .record_login_failure_at(alice, start + i)
            .await
            .unwrap();
    }
    let later = start + 30 + FORGET_AFTER_MS + 1;
    store.record_login_failure_at(alice, later).await.unwrap();
    assert!(!store.login_throttled_at(alice, later).await.unwrap());
}
