// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Failed guesses slow the guesser's own address for that account, never the real owner, and
//! nobody is locked out for good.
#![allow(dead_code)]

use axum::Router;
use axum::http::StatusCode;
use serde_json::json;
use slimm_server::auth::Auth;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::{
    ACCOUNT_FREE_FAILURES, ACCOUNT_MAX_DELAY_MS, FORGET_AFTER_MS, FREE_FAILURES, MAX_DELAY_MS,
    Store,
};
use tower::ServiceExt;

mod support;
mod totp_support;

use totp_support::{PASSWORD, json_body, member, new_store, request};

/// The limiter key `login_from(1, ..)` produces under one trusted hop.
const SRC: &str = "ip:198.51.100.2";

/// The limiter key `login_from(7, ..)` produces.
const OTHER_SRC: &str = "ip:198.51.100.8";

/// Arms the throttle for one caller directly: the per-address limiter would refuse the burst first.
async fn arm(store: &Store, user: slimm_server::ids::UserId, source: &str) {
    for _ in 0..=FREE_FAILURES {
        store.record_login_failure(user, source).await.unwrap();
    }
}

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
async fn guesses_from_one_address_are_throttled_per_account() {
    let (store, auth, _guard) = new_store("slimm-login-throttle").await;
    let router = app(store.clone(), auth.clone());
    member(&store, &auth, "alice").await;
    let alice = store
        .live_user_id_by_username("alice")
        .await
        .unwrap()
        .unwrap();
    arm(&store, alice, OTHER_SRC).await;

    // The eleventh failure armed the throttle, so even the right password is a plain 401.
    let (wrong_status, wrong_error) = login_from(&router, 7, "alice", "wrong-password-2").await;
    let (status, error) = login_from(&router, 7, "alice", PASSWORD).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    assert_eq!((status, error), (wrong_status, wrong_error));
}

#[tokio::test]
async fn an_unknown_username_answers_like_a_throttled_account() {
    let (store, auth, _guard) = new_store("slimm-login-throttle-unknown").await;
    let router = app(store.clone(), auth.clone());
    member(&store, &auth, "alice").await;
    let alice = store
        .live_user_id_by_username("alice")
        .await
        .unwrap()
        .unwrap();
    arm(&store, alice, OTHER_SRC).await;
    let throttled = login_from(&router, 7, "alice", PASSWORD).await;
    let unknown = login_from(&router, 7, "nobody", PASSWORD).await;
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
            .record_login_failure_at(alice, SRC, start + i)
            .await
            .unwrap();
    }
    assert!(
        store
            .login_throttled_at(alice, SRC, start + 100)
            .await
            .unwrap()
    );
    assert!(
        !store
            .login_throttled_at(alice, SRC, start + 100 + MAX_DELAY_MS + 1)
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
    for _ in 0..FREE_FAILURES {
        store.record_login_failure(alice, SRC).await.unwrap();
    }
    let (status, _) = login_from(&router, 1, "alice", PASSWORD).await;
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
            .record_login_failure_at(alice, SRC, start + i)
            .await
            .unwrap();
    }
    let later = start + 30 + FORGET_AFTER_MS + 1;
    store
        .record_login_failure_at(alice, SRC, later)
        .await
        .unwrap();
    assert!(!store.login_throttled_at(alice, SRC, later).await.unwrap());
}

#[tokio::test]
async fn a_strangers_guesses_never_keep_the_owner_out() {
    let (store, auth, _guard) = new_store("slimm-login-throttle-stranger").await;
    let router = app(store.clone(), auth.clone());
    member(&store, &auth, "alice").await;
    let alice = store
        .live_user_id_by_username("alice")
        .await
        .unwrap()
        .unwrap();
    arm(&store, alice, OTHER_SRC).await;

    let (status, _) = login_from(&router, 7, "alice", PASSWORD).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED, "the stranger is slowed");

    let (status, _) = login_from(&router, 1, "alice", PASSWORD).await;
    assert_eq!(status, StatusCode::OK, "the owner from elsewhere is not");
}

#[tokio::test]
async fn stale_throttle_rows_are_swept() {
    let (store, auth, _guard) = new_store("slimm-login-throttle-sweep").await;
    member(&store, &auth, "alice").await;
    let alice = store
        .live_user_id_by_username("alice")
        .await
        .unwrap()
        .unwrap();
    let start = now_ms();
    store
        .record_login_failure_at(alice, SRC, start)
        .await
        .unwrap();
    assert_eq!(store.sweep_login_throttle_at(start + 1).await.unwrap(), 0);
    let later = start + FORGET_AFTER_MS + 1;
    assert_eq!(
        store.sweep_login_throttle_at(later).await.unwrap(),
        2,
        "the caller's row and the account-wide row"
    );
}

#[tokio::test]
async fn guessing_from_many_addresses_spends_the_account_budget() {
    let (store, auth, _guard) = new_store("slimm-login-throttle-distributed").await;
    let router = app(store.clone(), auth.clone());
    member(&store, &auth, "alice").await;

    // One wrong guess per address never trips an address's own budget.
    for ip in 0..=ACCOUNT_FREE_FAILURES as usize {
        let (status, _) = login_from(&router, ip, "alice", "wrong-password-2").await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
    }
    let (status, _) = login_from(&router, 200, "alice", PASSWORD).await;
    assert_eq!(
        status,
        StatusCode::UNAUTHORIZED,
        "the account itself is slowed, whatever address asks"
    );
}

#[tokio::test]
async fn the_account_budget_is_not_spent_by_a_few_honest_typos() {
    let (store, auth, _guard) = new_store("slimm-login-throttle-typos").await;
    let router = app(store.clone(), auth.clone());
    member(&store, &auth, "alice").await;
    for ip in 0..ACCOUNT_FREE_FAILURES as usize {
        login_from(&router, ip, "alice", "wrong-password-2").await;
    }
    let (status, _) = login_from(&router, 200, "alice", PASSWORD).await;
    assert_eq!(status, StatusCode::OK);
}

#[tokio::test]
async fn the_owner_signs_in_after_the_account_delay_and_that_ends_the_guessing() {
    let (store, auth, _guard) = new_store("slimm-login-throttle-account-recover").await;
    let router = app(store.clone(), auth.clone());
    member(&store, &auth, "alice").await;
    let alice = store
        .live_user_id_by_username("alice")
        .await
        .unwrap()
        .unwrap();

    let start = now_ms() - ACCOUNT_MAX_DELAY_MS - 10_000;
    for i in 0..200 {
        let source = format!("ip:203.0.113.{}", i % 250);
        store
            .record_login_failure_at(alice, &source, start + i)
            .await
            .unwrap();
    }
    let fresh = "ip:198.51.100.1";
    assert!(
        store
            .login_throttled_at(alice, fresh, start + 200)
            .await
            .unwrap()
    );
    assert!(
        !store
            .login_throttled_at(alice, fresh, start + 200 + ACCOUNT_MAX_DELAY_MS + 1)
            .await
            .unwrap(),
        "the account delay is bounded and short"
    );

    let (status, _) = login_from(&router, 1, "alice", PASSWORD).await;
    assert_eq!(status, StatusCode::OK);
    assert!(
        !store
            .login_throttled_at(alice, fresh, now_ms())
            .await
            .unwrap()
    );
    for ip in 0..=FREE_FAILURES as usize {
        login_from(&router, ip, "alice", "wrong-password-2").await;
    }
    let (status, _) = login_from(&router, 201, "alice", PASSWORD).await;
    assert_eq!(
        status,
        StatusCode::OK,
        "the correct password reset the count"
    );
}
