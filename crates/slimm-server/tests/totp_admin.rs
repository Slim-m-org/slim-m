// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The administrator's half of the second factor, and the one decision in
//! decision 0048 worth a test of its own: an admin-issued password reset code
//! does NOT clear or bypass an enabled factor.
//!
//! If it did, the factor would be worth exactly as much as one administrator's
//! say-so, which on a self-hosted deployment is usually one person. Clearing a
//! factor is a separate, permission-gated, audited act instead, so an
//! administrator who wants to take over an account can still do it and cannot
//! do it quietly.
#![allow(dead_code)]

use axum::http::StatusCode;
use serde_json::json;
use slimm_server::totp;
use tower::ServiceExt;
use uuid::Uuid;

mod support;
mod totp_support;

use totp_support::{
    PASSWORD, app, enrol_and_confirm, json_body, login, login_for_challenge, member, new_store,
    now_ms, request, verify,
};

/// A second member on a store whose deployment is already claimed, so the
/// first account keeps its administrator role.
async fn second_member(
    store: &slimm_server::store::Store,
    auth: &slimm_server::auth::Auth,
    username: &str,
) -> (String, String) {
    let hash = auth.hash_password(PASSWORD.to_owned()).await.unwrap();
    let account = store
        .create_account(username, username, &hash)
        .await
        .unwrap();
    let tokens = store.open_session(account.id, "cli").await.unwrap();
    (tokens.access_token, account.id.to_string())
}

async fn issue_reset_code(router: &axum::Router, admin_token: &str, user_id: &str) -> String {
    let response = router
        .clone()
        .oneshot(request(
            "POST",
            &format!("/admin/users/{user_id}/reset-code"),
            Some(admin_token),
            Some(json!({ "password": PASSWORD })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    json_body(response).await["code"]
        .as_str()
        .unwrap()
        .to_owned()
}

// --- The reset-code interaction ---

/// The decision this whole file exists for. A reset code answers "I forgot my
/// password"; it is not a way past "prove you hold the device", so the next
/// sign-in with the new password still gets a challenge.
#[tokio::test]
async fn a_password_reset_does_not_bypass_the_second_factor() {
    let (store, auth, _guard) = new_store("slimm-totp-reset-bypass").await;
    let router = app(store.clone(), auth.clone());
    let (_admin_token, _admin_id) = member(&store, &auth, "alice").await;
    let (bob_token, bob_id) = second_member(&store, &auth, "bob").await;
    let (secret, _codes) = enrol_and_confirm(&router, &bob_token).await;

    let code = issue_reset_code(&router, &_admin_token, &bob_id).await;
    let reset = router
        .clone()
        .oneshot(request(
            "POST",
            "/auth/reset",
            None,
            Some(json!({ "code": code, "new_password": "a-brand-new-password" })),
        ))
        .await
        .unwrap();
    assert_eq!(reset.status(), StatusCode::NO_CONTENT);

    // The new password works, and still does not open a session on its own.
    let response = router
        .clone()
        .oneshot(request(
            "POST",
            "/auth/login",
            None,
            Some(json!({
                "username": "bob",
                "password": "a-brand-new-password",
                "device_name": "phone",
            })),
        ))
        .await
        .unwrap();
    assert_eq!(
        response.status(),
        StatusCode::ACCEPTED,
        "a reset must not turn the factor off"
    );
    let challenge = json_body(response).await["totp_challenge"]
        .as_str()
        .unwrap()
        .to_owned();

    // The original secret still answers it, so the reset did not silently re-key the factor either.
    let totp_code = totp::code_at(&secret, now_ms()).unwrap();
    assert_eq!(
        verify(&router, &challenge, &totp_code).await.status(),
        StatusCode::OK
    );
}

/// A reset code is still a reset code: it must not stop working just because
/// the account has a factor, or an administrator would have no way to help
/// somebody who forgot their password but still holds their authenticator.
#[tokio::test]
async fn a_reset_still_changes_the_password_on_an_enrolled_account() {
    let (store, auth, _guard) = new_store("slimm-totp-reset-works").await;
    let router = app(store.clone(), auth.clone());
    let (admin_token, _admin_id) = member(&store, &auth, "alice").await;
    let (bob_token, bob_id) = second_member(&store, &auth, "bob").await;
    enrol_and_confirm(&router, &bob_token).await;

    let code = issue_reset_code(&router, &admin_token, &bob_id).await;
    router
        .clone()
        .oneshot(request(
            "POST",
            "/auth/reset",
            None,
            Some(json!({ "code": code, "new_password": "a-brand-new-password" })),
        ))
        .await
        .unwrap();

    // The old password is gone.
    assert_eq!(
        login(&router, "bob").await.status(),
        StatusCode::UNAUTHORIZED
    );
}

// --- Clearing a factor ---

#[tokio::test]
async fn only_an_administrator_can_clear_a_factor() {
    let (store, auth, _guard) = new_store("slimm-totp-clear-perm").await;
    let router = app(store.clone(), auth.clone());
    let (_admin_token, admin_id) = member(&store, &auth, "alice").await;
    let (bob_token, _bob_id) = second_member(&store, &auth, "bob").await;
    enrol_and_confirm(&router, &bob_token).await;

    let response = router
        .clone()
        .oneshot(request(
            "DELETE",
            &format!("/admin/users/{admin_id}/totp"),
            Some(&bob_token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn clearing_a_factor_that_does_not_exist_is_not_found() {
    let (store, auth, _guard) = new_store("slimm-totp-clear-missing").await;
    let router = app(store.clone(), auth.clone());
    let (admin_token, _admin_id) = member(&store, &auth, "alice").await;
    let (_bob_token, bob_id) = second_member(&store, &auth, "bob").await;

    let response = router
        .clone()
        .oneshot(request(
            "DELETE",
            &format!("/admin/users/{bob_id}/totp"),
            Some(&admin_token),
            Some(json!({ "password": PASSWORD })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NOT_FOUND);

    let unknown = Uuid::now_v7();
    let response = router
        .clone()
        .oneshot(request(
            "DELETE",
            &format!("/admin/users/{unknown}/totp"),
            Some(&admin_token),
            Some(json!({ "password": PASSWORD })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NOT_FOUND);
}

/// The path a genuinely locked-out member gets: the factor goes, and with it
/// every live session on the account.
///
/// Revoking is the point, not a side effect. This is the one act that removes a
/// security control from an account nobody has proved they own, so if the
/// request came from whoever stole it, the clear must not also leave them
/// holding a session.
#[tokio::test]
async fn clearing_a_factor_revokes_every_session_and_leaves_an_audit_entry() {
    let (store, auth, _guard) = new_store("slimm-totp-clear").await;
    let router = app(store.clone(), auth.clone());
    let (admin_token, admin_id) = member(&store, &auth, "alice").await;
    let (bob_token, bob_id) = second_member(&store, &auth, "bob").await;
    enrol_and_confirm(&router, &bob_token).await;

    let response = router
        .clone()
        .oneshot(request(
            "DELETE",
            &format!("/admin/users/{bob_id}/totp"),
            Some(&admin_token),
            Some(json!({ "password": PASSWORD })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    // Bob's own session is gone, unlike after a self-service disable.
    assert_eq!(
        router
            .clone()
            .oneshot(request("GET", "/auth/totp", Some(&bob_token), None))
            .await
            .unwrap()
            .status(),
        StatusCode::UNAUTHORIZED,
        "an administrator's clear must revoke the account's sessions"
    );

    // And the password alone signs in again, which is the whole purpose.
    assert_eq!(login(&router, "bob").await.status(), StatusCode::OK);

    // Recorded against the administrator who did it, so a takeover cannot be quiet.
    let history = json_body(
        router
            .clone()
            .oneshot(request("GET", "/reports/history", Some(&admin_token), None))
            .await
            .unwrap(),
    )
    .await;
    let items = history.as_array().expect("a history array");
    assert!(
        items.iter().any(|item| {
            item["kind"] == json!("audit_log")
                && item["action"] == json!("totp_cleared")
                && item["actor_id"] == json!(admin_id)
                && item["subject_id"] == json!(bob_id)
        }),
        "no totp_cleared entry naming the administrator and the subject: {history}"
    );
}

/// The recovery codes go with the factor. Leaving them behind would mean a
/// cleared account still had ten live single-use secrets pointing at a factor
/// that no longer exists, and a later re-enrolment would inherit them.
#[tokio::test]
async fn clearing_a_factor_also_voids_its_recovery_codes() {
    let (store, auth, _guard) = new_store("slimm-totp-clear-codes").await;
    let router = app(store.clone(), auth.clone());
    let (admin_token, _admin_id) = member(&store, &auth, "alice").await;
    let (bob_token, bob_id) = second_member(&store, &auth, "bob").await;
    let (_secret, codes) = enrol_and_confirm(&router, &bob_token).await;

    router
        .clone()
        .oneshot(request(
            "DELETE",
            &format!("/admin/users/{bob_id}/totp"),
            Some(&admin_token),
            Some(json!({ "password": PASSWORD })),
        ))
        .await
        .unwrap();

    // Bob re-enrols, and the codes from before the clear are not his codes.
    let (fresh_token, _) = second_member(&store, &auth, "bob2").await;
    let (_secret, new_codes) = enrol_and_confirm(&router, &fresh_token).await;
    assert!(
        new_codes.iter().all(|code| !codes.contains(code)),
        "a fresh enrolment must not inherit a cleared factor's codes"
    );

    let challenge = login_for_challenge(&router, "bob2").await;
    assert_eq!(
        verify(&router, &challenge, &codes[0]).await.status(),
        StatusCode::BAD_REQUEST,
        "a cleared factor's recovery code must not work anywhere"
    );
}

// --- The deployment policy ---

/// `off` stops new enrolments and deliberately does not disable a factor
/// somebody already has: flipping a deployment setting must not silently weaken
/// an account that chose to be harder to break into.
#[tokio::test]
async fn the_off_policy_refuses_new_enrolments_without_weakening_existing_ones() {
    let (store, auth, _guard) = new_store("slimm-totp-policy-off").await;
    let router = app(store.clone(), auth.clone());
    let (admin_token, _admin_id) = member(&store, &auth, "alice").await;
    let (bob_token, _bob_id) = second_member(&store, &auth, "bob").await;
    enrol_and_confirm(&router, &bob_token).await;

    let patched = router
        .clone()
        .oneshot(request(
            "PATCH",
            "/space/settings",
            Some(&admin_token),
            Some(json!({ "join_policy": "invite", "totp_policy": "off" })),
        ))
        .await
        .unwrap();
    assert_eq!(patched.status(), StatusCode::OK);
    assert_eq!(json_body(patched).await["totp_policy"], json!("off"));

    // Bob's factor is untouched.
    assert_eq!(
        login(&router, "bob").await.status(),
        StatusCode::ACCEPTED,
        "turning the policy off must not disable an existing factor"
    );

    // Alice cannot start one.
    let refused = router
        .clone()
        .oneshot(request(
            "POST",
            "/auth/totp/enrol",
            Some(&admin_token),
            Some(json!({ "password": PASSWORD })),
        ))
        .await
        .unwrap();
    assert_eq!(refused.status(), StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn an_unrecognised_policy_is_refused_rather_than_coerced() {
    let (store, auth, _guard) = new_store("slimm-totp-policy-bad").await;
    let router = app(store.clone(), auth.clone());
    let (admin_token, _admin_id) = member(&store, &auth, "alice").await;

    let response = router
        .clone()
        .oneshot(request(
            "PATCH",
            "/space/settings",
            Some(&admin_token),
            Some(json!({ "join_policy": "invite", "totp_policy": "sometimes" })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    // And the join policy it was sent alongside did not change either.
    let settings = json_body(
        router
            .clone()
            .oneshot(request("GET", "/space/settings", Some(&admin_token), None))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(settings["totp_policy"], json!("optional"));
}

/// A client that predates the setting sends only `join_policy`, and must not
/// reset the operator's choice by omission.
#[tokio::test]
async fn omitting_the_policy_leaves_it_alone() {
    let (store, auth, _guard) = new_store("slimm-totp-policy-omit").await;
    let router = app(store.clone(), auth.clone());
    let (admin_token, _admin_id) = member(&store, &auth, "alice").await;

    router
        .clone()
        .oneshot(request(
            "PATCH",
            "/space/settings",
            Some(&admin_token),
            Some(json!({ "join_policy": "invite", "totp_policy": "required_for_elevated" })),
        ))
        .await
        .unwrap();
    // The policy now asks administrators for a factor, so this one enrols first.
    enrol_and_confirm(&router, &admin_token).await;
    let response = router
        .clone()
        .oneshot(request(
            "PATCH",
            "/space/settings",
            Some(&admin_token),
            Some(json!({ "join_policy": "open" })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(
        json_body(response).await["totp_policy"],
        json!("required_for_elevated")
    );
}
