// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Living with the factor once it is on (decision 0048): spending a recovery
//! code, reissuing the set, turning the factor off, and what that does to the
//! member's other sessions.
//!
//! Split from `tests/it_accounts/totp.rs`, which covers getting it switched on and meeting
//! it at sign-in, so neither file sits over the review budget.
#![allow(dead_code)]

use axum::http::StatusCode;
use serde_json::json;
use slimm_server::hub::{Event, Hub};
use slimm_server::totp;
use tower::ServiceExt;

use crate::totp_support;
use totp_support::{
    app, app_with_hub, enrol_and_confirm, json_body, login, login_for_challenge, member, new_store,
    now_ms, request, verify,
};

// --- Recovery codes ---

#[tokio::test]
async fn a_recovery_code_completes_a_sign_in_exactly_once() {
    let (store, auth, _guard) = new_store("slimm-totp-recovery").await;
    let app = app(store.clone(), auth.clone());
    let (token, _id) = member(&store, &auth, "ada").await;
    let (_secret, codes) = enrol_and_confirm(&app, &token).await;

    let challenge = login_for_challenge(&app, "ada").await;
    let response = verify(&app, &challenge, &codes[0]).await;
    assert_eq!(response.status(), StatusCode::OK);
    let session = json_body(response).await["access_token"]
        .as_str()
        .unwrap()
        .to_owned();

    let status = json_body(
        app.clone()
            .oneshot(request("GET", "/auth/totp", Some(&session), None))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(
        status["recovery_codes_remaining"],
        json!(slimm_server::store::RECOVERY_CODE_COUNT - 1),
        "spending one code should leave the rest"
    );

    let again = login_for_challenge(&app, "ada").await;
    assert_eq!(
        verify(&app, &again, &codes[0]).await.status(),
        StatusCode::BAD_REQUEST,
        "a spent recovery code must not work twice"
    );
    // A different one still works, so the refusal above is about that code, not the set.
    let third = login_for_challenge(&app, "ada").await;
    assert_eq!(
        verify(&app, &third, &codes[1]).await.status(),
        StatusCode::OK
    );
}

/// A recovery code is read off a screen and typed somewhere else, so it is
/// accepted the way people actually retype it: without the grouping dashes, in
/// the wrong case, or with the groups spaced out instead.
#[tokio::test]
async fn a_recovery_code_is_accepted_however_it_was_retyped() {
    let (store, auth, _guard) = new_store("slimm-totp-retyped").await;
    let app = app(store.clone(), auth.clone());
    let (token, _id) = member(&store, &auth, "ada").await;
    let (_secret, codes) = enrol_and_confirm(&app, &token).await;

    let retyped = [
        codes[0].to_lowercase(),
        codes[1].replace('-', ""),
        codes[2].replace('-', " "),
    ];
    for (index, code) in retyped.iter().enumerate() {
        let challenge = login_for_challenge(&app, "ada").await;
        assert_eq!(
            verify(&app, &challenge, code).await.status(),
            StatusCode::OK,
            "form {index} ({code:?}) should be accepted"
        );
    }
}

/// The shape a person has to transcribe, asserted from the route rather than
/// the generator, so a store or handler that reformatted them would be caught.
#[tokio::test]
async fn recovery_codes_arrive_grouped_and_short_enough_to_write_down() {
    let (store, auth, _guard) = new_store("slimm-totp-shape").await;
    let app = app(store.clone(), auth.clone());
    let (token, _id) = member(&store, &auth, "ada").await;
    let (_secret, codes) = enrol_and_confirm(&app, &token).await;

    for code in &codes {
        assert_eq!(code.len(), 23, "{code} is longer than a person will copy");
        assert_eq!(code.matches('-').count(), 3, "{code} is not grouped");
    }
}

#[tokio::test]
async fn reissuing_replaces_the_whole_recovery_set() {
    let (store, auth, _guard) = new_store("slimm-totp-reissue").await;
    let app = app(store.clone(), auth.clone());
    let (token, _id) = member(&store, &auth, "ada").await;
    let (secret, codes) = enrol_and_confirm(&app, &token).await;

    let code = totp::code_at(&secret, now_ms()).unwrap();
    let response = app
        .clone()
        .oneshot(request(
            "POST",
            "/auth/totp/recovery-codes",
            Some(&token),
            Some(json!({ "code": code })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let fresh: Vec<String> = json_body(response).await["recovery_codes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap().to_owned())
        .collect();
    assert_eq!(fresh.len(), slimm_server::store::RECOVERY_CODE_COUNT);
    assert!(
        fresh.iter().all(|c| !codes.contains(c)),
        "the reissued set must not reuse a code from the old one"
    );

    let challenge = login_for_challenge(&app, "ada").await;
    assert_eq!(
        verify(&app, &challenge, &codes[0]).await.status(),
        StatusCode::BAD_REQUEST,
        "an old recovery code must stop working"
    );
    let next = login_for_challenge(&app, "ada").await;
    assert_eq!(
        verify(&app, &next, &fresh[0]).await.status(),
        StatusCode::OK
    );
}

// --- Disabling ---

#[tokio::test]
async fn disabling_needs_a_code_and_then_stops_the_challenge() {
    let (store, auth, _guard) = new_store("slimm-totp-disable").await;
    let app = app(store.clone(), auth.clone());
    let (token, _id) = member(&store, &auth, "ada").await;
    let (secret, _codes) = enrol_and_confirm(&app, &token).await;

    let refused = app
        .clone()
        .oneshot(request(
            "POST",
            "/auth/totp/disable",
            Some(&token),
            Some(json!({ "code": "000000" })),
        ))
        .await
        .unwrap();
    assert_eq!(refused.status(), StatusCode::BAD_REQUEST);
    assert_eq!(
        login(&app, "ada").await.status(),
        StatusCode::ACCEPTED,
        "a refused disable must leave the factor on"
    );

    let code = totp::code_at(&secret, now_ms()).unwrap();
    let response = app
        .clone()
        .oneshot(request(
            "POST",
            "/auth/totp/disable",
            Some(&token),
            Some(json!({ "code": code })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);
    assert_eq!(
        login(&app, "ada").await.status(),
        StatusCode::OK,
        "signing in should be back to password only"
    );
}

/// A recovery code is exactly what somebody whose phone is gone has to disable
/// with, so it has to be accepted here too.
#[tokio::test]
async fn disabling_accepts_a_recovery_code() {
    let (store, auth, _guard) = new_store("slimm-totp-disable-recovery").await;
    let app = app(store.clone(), auth.clone());
    let (token, _id) = member(&store, &auth, "ada").await;
    let (_secret, codes) = enrol_and_confirm(&app, &token).await;

    let response = app
        .clone()
        .oneshot(request(
            "POST",
            "/auth/totp/disable",
            Some(&token),
            Some(json!({ "code": codes[0].clone() })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);
    assert_eq!(login(&app, "ada").await.status(), StatusCode::OK);
}

/// decision 0048's session call, asserted rather than left as prose: turning
/// the factor on and off does not sign the member's other devices out, because
/// they proved both factors to get here. The administrator's clear, which has
/// no such proof, does revoke; `tests/it_accounts/totp_admin.rs` pins that half.
#[tokio::test]
async fn enabling_and_disabling_leave_existing_sessions_alone() {
    let (store, auth, _guard) = new_store("slimm-totp-sessions").await;
    let app = app(store.clone(), auth.clone());
    let (token, _id) = member(&store, &auth, "ada").await;

    let (secret, _codes) = enrol_and_confirm(&app, &token).await;
    assert_eq!(
        app.clone()
            .oneshot(request("GET", "/auth/totp", Some(&token), None))
            .await
            .unwrap()
            .status(),
        StatusCode::OK,
        "enrolling must not revoke the session that did the enrolling"
    );

    let code = totp::code_at(&secret, now_ms()).unwrap();
    app.clone()
        .oneshot(request(
            "POST",
            "/auth/totp/disable",
            Some(&token),
            Some(json!({ "code": code })),
        ))
        .await
        .unwrap();
    assert_eq!(
        app.clone()
            .oneshot(request("GET", "/auth/totp", Some(&token), None))
            .await
            .unwrap()
            .status(),
        StatusCode::OK,
        "disabling must not revoke the session either"
    );
}

// --- Lockout on a change ---

/// Spends the failure budget on `path`, then offers a correct code through a fresh router.
async fn lock_then_offer_correct_code(path: &str, prefix: &str) -> StatusCode {
    let (store, auth, _guard) = new_store(prefix).await;
    let first = app(store.clone(), auth.clone());
    let (token, _id) = member(&store, &auth, "ada").await;
    let (secret, _codes) = enrol_and_confirm(&first, &token).await;
    for attempt in 0..totp::MAX_FAILURES {
        let refused = first
            .clone()
            .oneshot(request(
                "POST",
                path,
                Some(&token),
                Some(json!({ "code": "000000" })),
            ))
            .await
            .unwrap();
        assert_eq!(
            refused.status(),
            StatusCode::BAD_REQUEST,
            "attempt {attempt}"
        );
    }
    let restarted = app(store.clone(), auth.clone());
    let code = totp::code_at(&secret, now_ms()).unwrap();
    let status = restarted
        .clone()
        .oneshot(request(
            "POST",
            path,
            Some(&token),
            Some(json!({ "code": code })),
        ))
        .await
        .unwrap()
        .status();
    let challenge = login(&restarted, "ada").await.status();
    assert_eq!(challenge, StatusCode::ACCEPTED, "the factor is still on");
    status
}

#[tokio::test]
async fn repeated_wrong_codes_lock_disabling_even_against_a_correct_code() {
    let status =
        lock_then_offer_correct_code("/auth/totp/disable", "slimm-totp-lock-disable").await;
    assert_eq!(status, StatusCode::TOO_MANY_REQUESTS);
}

#[tokio::test]
async fn repeated_wrong_codes_lock_reissuing_even_against_a_correct_code() {
    let status =
        lock_then_offer_correct_code("/auth/totp/recovery-codes", "slimm-totp-lock-reissue").await;
    assert_eq!(status, StatusCode::TOO_MANY_REQUESTS);
}

// --- Sign-in alert ---

#[tokio::test]
async fn a_totp_sign_in_alerts_the_other_devices() {
    let (store, auth, _guard) = new_store("slimm-totp-sign-in-alert").await;
    let hub = Hub::new();
    let app = app_with_hub(store.clone(), auth.clone(), hub.clone());
    let (token, _id) = member(&store, &auth, "ada").await;
    let (secret, _codes) = enrol_and_confirm(&app, &token).await;

    let challenge = login_for_challenge(&app, "ada").await;
    let mut rx = hub.subscribe();
    let code = totp::code_at(&secret, now_ms()).unwrap();
    assert_eq!(
        verify(&app, &challenge, &code).await.status(),
        StatusCode::OK
    );

    let mut alerted = None;
    while let Ok(event) = rx.try_recv() {
        if let Event::NewDeviceSignIn { device_name, .. } = event {
            alerted = Some(device_name);
        }
    }
    assert_eq!(alerted.as_deref(), Some("phone"));
}
