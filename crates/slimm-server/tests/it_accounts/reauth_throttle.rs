// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Password re-authentication feeds the sign-in throttle, so a stolen session token cannot grind
//! the password through the routes that guard the destructive changes.
#![allow(dead_code)]

use axum::Router;
use axum::http::StatusCode;
use serde_json::json;
use slimm_server::auth::Auth;
use slimm_server::ids::UserId;
use slimm_server::store::{ACCOUNT_FREE_FAILURES, FREE_FAILURES, Store};
use tower::ServiceExt;

use crate::support;
use crate::totp_support;
use totp_support::{PASSWORD, app, json_body, member, new_store, request};

/// Starts two-factor enrolment, which asks for the password and changes nothing until confirmed.
async fn reauth(router: &Router, token: &str, password: &str) -> axum::response::Response {
    router
        .clone()
        .oneshot(request(
            "POST",
            "/auth/totp/enrol",
            Some(token),
            Some(json!({ "password": password })),
        ))
        .await
        .unwrap()
}

async fn signed_in(prefix: &str) -> (Store, Auth, Router, String, UserId, support::TestDbGuard) {
    let (store, auth, guard) = new_store(prefix).await;
    let router = app(store.clone(), auth.clone());
    let (token, _) = member(&store, &auth, "alice").await;
    let alice = store
        .live_user_id_by_username("alice")
        .await
        .unwrap()
        .unwrap();
    (store, auth, router, token, alice, guard)
}

fn own_source(user: UserId) -> String {
    format!("u:{user}")
}

#[tokio::test]
async fn a_wrong_password_is_counted_and_the_first_past_the_free_budget_locks_the_caller() {
    let (store, _auth, router, token, alice, _guard) = signed_in("slimm-reauth-count").await;
    let source = own_source(alice);
    for _ in 0..FREE_FAILURES {
        store.record_login_failure(alice, &source).await.unwrap();
    }
    assert!(!store.login_throttled(alice, &source).await.unwrap());

    let response = reauth(&router, &token, "wrong-password-2").await;
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
    assert!(
        store.login_throttled(alice, &source).await.unwrap(),
        "the wrong password was not counted"
    );
}

#[tokio::test]
async fn a_locked_caller_is_refused_even_with_the_right_password_and_told_how_long_to_wait() {
    let (store, _auth, router, token, alice, _guard) = signed_in("slimm-reauth-locked").await;
    let source = own_source(alice);
    for _ in 0..=FREE_FAILURES {
        store.record_login_failure(alice, &source).await.unwrap();
    }

    let response = reauth(&router, &token, PASSWORD).await;
    assert_eq!(response.status(), StatusCode::TOO_MANY_REQUESTS);
    let retry_after: u64 = response
        .headers()
        .get("retry-after")
        .expect("a Retry-After header")
        .to_str()
        .unwrap()
        .parse()
        .unwrap();
    assert!((1..=15).contains(&retry_after), "waits {retry_after}s");
    assert_eq!(
        json_body(response).await["retry_after_seconds"],
        retry_after
    );
}

#[tokio::test]
async fn guessing_the_password_from_elsewhere_slows_the_account_for_reauth_too() {
    let (store, _auth, router, token, alice, _guard) = signed_in("slimm-reauth-account").await;
    for ip in 0..=ACCOUNT_FREE_FAILURES {
        let source = format!("ip:203.0.113.{ip}");
        store.record_login_failure(alice, &source).await.unwrap();
    }

    let response = reauth(&router, &token, PASSWORD).await;
    assert_eq!(response.status(), StatusCode::TOO_MANY_REQUESTS);
}

#[tokio::test]
async fn a_strangers_sign_in_lockout_does_not_stop_the_owner_proving_themselves() {
    let (store, _auth, router, token, alice, _guard) = signed_in("slimm-reauth-stranger").await;
    for _ in 0..=FREE_FAILURES {
        store
            .record_login_failure(alice, "ip:203.0.113.9")
            .await
            .unwrap();
    }

    let response = reauth(&router, &token, PASSWORD).await;
    assert_eq!(response.status(), StatusCode::OK);
}

#[tokio::test]
async fn the_right_password_forgets_the_callers_failures() {
    let (store, _auth, router, token, alice, _guard) = signed_in("slimm-reauth-clear").await;
    let source = own_source(alice);
    for _ in 0..FREE_FAILURES - 1 {
        store.record_login_failure(alice, &source).await.unwrap();
    }

    let response = reauth(&router, &token, PASSWORD).await;
    assert_eq!(response.status(), StatusCode::OK);
    for _ in 0..FREE_FAILURES {
        store.record_login_failure(alice, &source).await.unwrap();
    }
    assert!(
        !store.login_throttled(alice, &source).await.unwrap(),
        "the earlier failures still counted"
    );
}
