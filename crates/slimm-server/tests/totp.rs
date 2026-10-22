// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Getting the factor switched on, and meeting it at sign-in (decision 0048):
//! enrolment that is not live until it is proved, verification and its window,
//! the replay guard, and the lockout.
//!
//! Recovery codes and disabling are in `tests/totp_lifecycle.rs`; the
//! administrator half, and the interaction with an admin-issued password reset,
//! are in `tests/totp_admin.rs`.
#![allow(dead_code)]

use axum::http::StatusCode;
use serde_json::json;
use slimm_server::totp;
use tower::ServiceExt;

mod support;
mod totp_support;

use totp_support::{
    PASSWORD, STEP_MS, app, begin_enrolment, enrol_and_confirm, json_body, login,
    login_for_challenge, member, new_store, now_ms, request, verify,
};

// --- Enrolment ---

/// The property that keeps somebody from locking themselves out with a
/// mis-scanned QR code: enrolling changes nothing about signing in until a code
/// off the authenticator has actually been verified.
#[tokio::test]
async fn an_unconfirmed_enrolment_is_not_enforced_at_sign_in() {
    let (store, auth, _guard) = new_store("slimm-totp-pending").await;
    let app = app(store.clone(), auth.clone());
    let (token, _id) = member(&store, &auth, "ada").await;

    begin_enrolment(&app, &token).await;

    let response = login(&app, "ada").await;
    assert_eq!(
        response.status(),
        StatusCode::OK,
        "a pending enrolment must not start demanding a code"
    );
    assert!(json_body(response).await["access_token"].is_string());

    let status = json_body(
        app.clone()
            .oneshot(request("GET", "/auth/totp", Some(&token), None))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(status["pending"], json!(true));
    assert_eq!(status["enabled"], json!(false));
}

#[tokio::test]
async fn confirming_with_a_wrong_code_leaves_the_factor_off() {
    let (store, auth, _guard) = new_store("slimm-totp-badconfirm").await;
    let app = app(store.clone(), auth.clone());
    let (token, _id) = member(&store, &auth, "ada").await;
    begin_enrolment(&app, &token).await;

    let response = app
        .clone()
        .oneshot(request(
            "POST",
            "/auth/totp/confirm",
            Some(&token),
            Some(json!({ "code": "000000", "password": PASSWORD })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    assert_eq!(login(&app, "ada").await.status(), StatusCode::OK);
}

#[tokio::test]
async fn confirming_switches_the_factor_on_and_hands_over_recovery_codes() {
    let (store, auth, _guard) = new_store("slimm-totp-confirm").await;
    let app = app(store.clone(), auth.clone());
    let (token, _id) = member(&store, &auth, "ada").await;

    let (_secret, codes) = enrol_and_confirm(&app, &token).await;
    assert_eq!(codes.len(), slimm_server::store::RECOVERY_CODE_COUNT);
    // Ten distinct codes, not one repeated ten times.
    let distinct: std::collections::HashSet<&String> = codes.iter().collect();
    assert_eq!(distinct.len(), codes.len());

    let status = json_body(
        app.clone()
            .oneshot(request("GET", "/auth/totp", Some(&token), None))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(status["enabled"], json!(true));
    assert_eq!(status["pending"], json!(false));
    assert_eq!(
        status["recovery_codes_remaining"],
        json!(slimm_server::store::RECOVERY_CODE_COUNT)
    );
}

/// Re-enrolling over a live factor would silently swap the secret out from
/// under the authenticator that already holds one, so it has to go through
/// disable instead.
#[tokio::test]
async fn enrolling_again_over_a_live_factor_is_a_conflict() {
    let (store, auth, _guard) = new_store("slimm-totp-reenrol").await;
    let app = app(store.clone(), auth.clone());
    let (token, _id) = member(&store, &auth, "ada").await;
    enrol_and_confirm(&app, &token).await;

    let response = app
        .clone()
        .oneshot(request(
            "POST",
            "/auth/totp/enrol",
            Some(&token),
            Some(json!({ "password": PASSWORD })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::CONFLICT);
}

// --- Verification at sign-in ---

#[tokio::test]
async fn a_correct_code_completes_the_sign_in() {
    let (store, auth, _guard) = new_store("slimm-totp-signin").await;
    let app = app(store.clone(), auth.clone());
    let (token, _id) = member(&store, &auth, "ada").await;
    let (secret, _codes) = enrol_and_confirm(&app, &token).await;

    let challenge = login_for_challenge(&app, "ada").await;
    let code = totp::code_at(&secret, now_ms()).unwrap();
    let response = verify(&app, &challenge, &code).await;
    assert_eq!(response.status(), StatusCode::OK);
    let body = json_body(response).await;
    assert!(body["access_token"].is_string());
    assert!(body["refresh_token"].is_string());
}

#[tokio::test]
async fn a_wrong_code_does_not_complete_the_sign_in() {
    let (store, auth, _guard) = new_store("slimm-totp-wrong").await;
    let app = app(store.clone(), auth.clone());
    let (token, _id) = member(&store, &auth, "ada").await;
    enrol_and_confirm(&app, &token).await;

    let challenge = login_for_challenge(&app, "ada").await;
    assert_eq!(
        verify(&app, &challenge, "000000").await.status(),
        StatusCode::BAD_REQUEST
    );
}

/// A wrong code must not burn the challenge, or one mistyped digit would cost a
/// whole fresh password round-trip. The attempt still counts against the
/// failure budget, which the lockout test below is what pins.
#[tokio::test]
async fn a_wrong_code_leaves_the_challenge_usable() {
    let (store, auth, _guard) = new_store("slimm-totp-retry").await;
    let app = app(store.clone(), auth.clone());
    let (token, _id) = member(&store, &auth, "ada").await;
    let (secret, _codes) = enrol_and_confirm(&app, &token).await;

    let challenge = login_for_challenge(&app, "ada").await;
    assert_eq!(
        verify(&app, &challenge, "000000").await.status(),
        StatusCode::BAD_REQUEST
    );

    let code = totp::code_at(&secret, now_ms()).unwrap();
    assert_eq!(
        verify(&app, &challenge, &code).await.status(),
        StatusCode::OK,
        "the same challenge should still work after a typo"
    );
}

/// The whole point of the challenge being single-use: a challenge read off a
/// log or a proxy cannot be replayed into a second session.
#[tokio::test]
async fn a_challenge_cannot_be_spent_twice() {
    let (store, auth, _guard) = new_store("slimm-totp-challenge-replay").await;
    let app = app(store.clone(), auth.clone());
    let (token, _id) = member(&store, &auth, "ada").await;
    let (secret, _codes) = enrol_and_confirm(&app, &token).await;

    let challenge = login_for_challenge(&app, "ada").await;
    let code = totp::code_at(&secret, now_ms()).unwrap();
    assert_eq!(
        verify(&app, &challenge, &code).await.status(),
        StatusCode::OK
    );
    assert_eq!(
        verify(&app, &challenge, &code).await.status(),
        StatusCode::UNAUTHORIZED,
        "a spent challenge must be refused"
    );
}

/// A code read off somebody's screen must not work behind them, even inside its
/// own thirty-second window. This is the replay guard, and it is distinct from
/// the challenge being single-use: here the second attempt brings a fresh
/// challenge and the same still-current code.
#[tokio::test]
async fn a_code_cannot_be_used_twice_even_inside_its_own_window() {
    let (store, auth, _guard) = new_store("slimm-totp-replay").await;
    let app = app(store.clone(), auth.clone());
    let (token, _id) = member(&store, &auth, "ada").await;
    let (secret, _codes) = enrol_and_confirm(&app, &token).await;

    let code = totp::code_at(&secret, now_ms()).unwrap();
    let first = login_for_challenge(&app, "ada").await;
    assert_eq!(verify(&app, &first, &code).await.status(), StatusCode::OK);

    let second = login_for_challenge(&app, "ada").await;
    assert_eq!(
        verify(&app, &second, &code).await.status(),
        StatusCode::BAD_REQUEST,
        "the same code must not be spendable a second time"
    );
}

/// Confirmation spends a step too, so the code that turned the factor on cannot
/// then be replayed into the first sign-in.
#[tokio::test]
async fn the_confirming_code_cannot_be_replayed_at_sign_in() {
    let (store, auth, _guard) = new_store("slimm-totp-confirm-replay").await;
    let app = app(store.clone(), auth.clone());
    let (token, _id) = member(&store, &auth, "ada").await;

    let secret = begin_enrolment(&app, &token).await;
    let code = totp::code_at(&secret, now_ms()).unwrap();
    let confirmed = app
        .clone()
        .oneshot(request(
            "POST",
            "/auth/totp/confirm",
            Some(&token),
            Some(json!({ "code": code.clone(), "password": PASSWORD })),
        ))
        .await
        .unwrap();
    assert_eq!(confirmed.status(), StatusCode::OK);

    let challenge = login_for_challenge(&app, "ada").await;
    assert_eq!(
        verify(&app, &challenge, &code).await.status(),
        StatusCode::BAD_REQUEST
    );
}

/// Sleeps until the clock is well inside a step, so a test that makes several requests does not straddle a step edge.
fn collides_with_window(secret: &str, code: &str, at_ms: i64) -> bool {
    (-1..=1).any(|step| totp::code_at(secret, at_ms + step * STEP_MS).unwrap() == code)
}

async fn wait_for_mid_step() {
    let into_step = now_ms().rem_euclid(STEP_MS);
    if !(5_000..=15_000).contains(&into_step) {
        let wait = (STEP_MS - into_step + 5_000).rem_euclid(STEP_MS);
        tokio::time::sleep(std::time::Duration::from_millis(wait as u64)).await;
    }
}

/// One step either side is accepted for clock skew; two is not. Asserted from
/// the route rather than the primitive, so a store or handler that widened the
/// window on its own would still be caught.
#[tokio::test]
async fn a_code_just_outside_the_window_is_refused() {
    let (store, auth, _guard) = new_store("slimm-totp-window").await;
    let app = app(store.clone(), auth.clone());
    let (token, _id) = member(&store, &auth, "ada").await;
    wait_for_mid_step().await;
    let (secret, _codes) = enrol_and_confirm(&app, &token).await;

    // The server reads its own clock, so a request that straddles a step edge sees a different step than the code was made for; retry such a run.
    for offset in [-2 * STEP_MS, 2 * STEP_MS] {
        let mut status = StatusCode::OK;
        for _ in 0..5 {
            let started = now_ms();
            let code = totp::code_at(&secret, started + offset).unwrap();
            // Six digits repeat: an out-of-window code equal to an in-window one proves nothing, so wait for the next step.
            if collides_with_window(&secret, &code, started) {
                tokio::time::sleep(std::time::Duration::from_millis(STEP_MS as u64)).await;
                continue;
            }
            let challenge = login_for_challenge(&app, "ada").await;
            status = verify(&app, &challenge, &code).await.status();
            if now_ms() / STEP_MS == started / STEP_MS {
                break;
            }
        }
        assert_eq!(
            status,
            StatusCode::BAD_REQUEST,
            "a code {} steps out must be refused",
            offset / STEP_MS
        );
    }

    // The next step is inside the window and never spent: enrolment spent the current one, so the replay guard would refuse a code for it.
    let mut status = StatusCode::BAD_REQUEST;
    for _ in 0..5 {
        let started = now_ms();
        let code = totp::code_at(&secret, started + STEP_MS).unwrap();
        let challenge = login_for_challenge(&app, "ada").await;
        status = verify(&app, &challenge, &code).await.status();
        if status == StatusCode::OK || now_ms() / STEP_MS == started / STEP_MS {
            break;
        }
    }
    assert_eq!(status, StatusCode::OK);
}

// --- Lockout ---

/// Guessing six digits has to be bounded by something other than the
/// in-process rate limiter, which resets when the process does. After the
/// budget is spent even a correct code is refused, which is what makes it a
/// lockout rather than a delay.
///
/// The final assertion goes through a *second* router over the same database,
/// which is the whole point: a fresh router has a fresh `RateLimiter`, so a 429
/// from it can only be the stored lockout. Asserted against the original router
/// this test passed on the limiter's own refusal instead, which is how the
/// budget ordering in `ratelimit::Class::Totp` came to be wrong.
#[tokio::test]
async fn repeated_failures_lock_the_factor_even_against_a_correct_code() {
    let (store, auth, _guard) = new_store("slimm-totp-lockout").await;
    let first = app(store.clone(), auth.clone());
    let (token, _id) = member(&store, &auth, "ada").await;
    let (secret, _codes) = enrol_and_confirm(&first, &token).await;

    let challenge = login_for_challenge(&first, "ada").await;
    for attempt in 0..totp::MAX_FAILURES {
        assert_eq!(
            verify(&first, &challenge, "000000").await.status(),
            StatusCode::BAD_REQUEST,
            "attempt {attempt} should be a plain refusal, not yet a lock"
        );
    }

    let restarted = app(store.clone(), auth.clone());
    let code = totp::code_at(&secret, now_ms()).unwrap();
    assert_eq!(
        verify(&restarted, &challenge, &code).await.status(),
        StatusCode::TOO_MANY_REQUESTS,
        "a correct code must be refused while the factor is locked, and the \
         lock must survive a restart"
    );
}

/// The counter is a run, not a total: getting it right resets it, so somebody
/// who fumbles four codes over a week never accumulates their way into a lock.
///
/// A fresh router per run, so the address's rate bucket cannot be what refuses
/// the second run's attempts and make this pass for the wrong reason.
#[tokio::test]
async fn a_success_clears_the_failure_run() {
    let (store, auth, _guard) = new_store("slimm-totp-reset-run").await;
    let first = app(store.clone(), auth.clone());
    let (token, _id) = member(&store, &auth, "ada").await;
    let (secret, _codes) = enrol_and_confirm(&first, &token).await;

    let challenge = login_for_challenge(&first, "ada").await;
    for _ in 0..(totp::MAX_FAILURES - 1) {
        verify(&first, &challenge, "000000").await;
    }
    let code = totp::code_at(&secret, now_ms()).unwrap();
    assert_eq!(
        verify(&first, &challenge, &code).await.status(),
        StatusCode::OK
    );

    let second = app(store.clone(), auth.clone());
    let next = login_for_challenge(&second, "ada").await;
    for attempt in 0..(totp::MAX_FAILURES - 1) {
        assert_eq!(
            verify(&second, &next, "000000").await.status(),
            StatusCode::BAD_REQUEST,
            "attempt {attempt} of a fresh run must not be a lock"
        );
    }
}
