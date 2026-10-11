// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `required_for_elevated` is enforced where an elevated permission is used
//! (decision 0048): an administrator with no factor is refused, with a reason
//! that is not "insufficient permissions", while sign-in and enrolment stay open.
#![allow(dead_code)]

use axum::http::StatusCode;
use serde_json::json;
use slimm_server::permissions::Permissions;
use slimm_server::store::{Store, TotpPolicy};
use tower::ServiceExt;

mod support;
mod totp_support;

use totp_support::{PASSWORD, app, enrol_and_confirm, json_body, member, new_store, request};

const NEEDS_FACTOR: &str =
    "turn on two-factor sign-in in your account settings before using administrator powers";

async fn bob_id(store: &Store, auth: &slimm_server::auth::Auth) -> String {
    let hash = auth.hash_password(PASSWORD.to_owned()).await.unwrap();
    let bob = store.create_account("bob", "bob", &hash).await.unwrap();
    bob.id.to_string()
}

async fn status_and_error(
    router: &axum::Router,
    method: &str,
    uri: &str,
    token: &str,
    body: Option<serde_json::Value>,
) -> (StatusCode, String) {
    let response = router
        .clone()
        .oneshot(request(method, uri, Some(token), body))
        .await
        .unwrap();
    let status = response.status();
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    let error = serde_json::from_slice::<serde_json::Value>(&bytes)
        .ok()
        .and_then(|v| v["error"].as_str().map(str::to_owned))
        .unwrap_or_default();
    (status, error)
}

#[tokio::test]
async fn an_administrator_without_a_factor_is_refused_under_the_policy() {
    let (store, auth, _guard) = new_store("slimm-totp-elevated").await;
    let router = app(store.clone(), auth.clone());
    let (admin_token, _) = member(&store, &auth, "alice").await;
    let bob = bob_id(&store, &auth).await;
    let reset = format!("/admin/users/{bob}/reset-code");

    let (open, _) = status_and_error(
        &router,
        "POST",
        &reset,
        &admin_token,
        Some(json!({ "password": PASSWORD })),
    )
    .await;
    assert_eq!(open, StatusCode::OK, "optional policy asks nothing");

    store
        .set_totp_policy(TotpPolicy::RequiredForElevated)
        .await
        .unwrap();
    for (method, uri, body) in [
        ("POST", reset.as_str(), None),
        (
            "PATCH",
            "/space/settings",
            Some(json!({ "join_policy": "invite" })),
        ),
        ("PUT", &format!("/members/{bob}/removal"), Some(json!({}))),
    ] {
        let (status, error) = status_and_error(&router, method, uri, &admin_token, body).await;
        assert_eq!(
            (status, error.as_str()),
            (StatusCode::FORBIDDEN, NEEDS_FACTOR),
            "{uri}"
        );
    }

    enrol_and_confirm(&router, &admin_token).await;
    let (status, _) = status_and_error(
        &router,
        "POST",
        &reset,
        &admin_token,
        Some(json!({ "password": PASSWORD })),
    )
    .await;
    assert_eq!(
        status,
        StatusCode::OK,
        "enrolled, the same call goes through"
    );
}

#[tokio::test]
async fn the_policy_leaves_sign_in_enrolment_and_ordinary_use_open() {
    let (store, auth, _guard) = new_store("slimm-totp-elevated-open").await;
    let router = app(store.clone(), auth.clone());
    let (admin_token, _) = member(&store, &auth, "alice").await;
    store
        .set_totp_policy(TotpPolicy::RequiredForElevated)
        .await
        .unwrap();

    let (status, _) = status_and_error(&router, "GET", "/auth/totp", &admin_token, None).await;
    assert_eq!(status, StatusCode::OK);
    let (status, _) = status_and_error(&router, "GET", "/channels", &admin_token, None).await;
    assert_eq!(status, StatusCode::OK, "ordinary reads are not elevated");
    enrol_and_confirm(&router, &admin_token).await;
    let login = totp_support::login(&router, "alice").await;
    assert_eq!(login.status(), StatusCode::ACCEPTED, "sign-in still works");
    let _ = json_body(login).await;
}

#[tokio::test]
async fn a_bot_holding_administrator_is_not_locked_out_by_the_policy() {
    let (store, auth, _guard) = new_store("slimm-totp-elevated-bot").await;
    let router = app(store.clone(), auth.clone());
    let (_admin_token, admin_id) = member(&store, &auth, "alice").await;
    let creator = slimm_server::ids::UserId(admin_id.parse().unwrap());
    let bot = store
        .create_bot("helper", "helper", Permissions::ADMINISTRATOR, creator)
        .await
        .unwrap();
    store
        .set_totp_policy(TotpPolicy::RequiredForElevated)
        .await
        .unwrap();
    let bob = bob_id(&store, &auth).await;

    let (status, _) = status_and_error(
        &router,
        "POST",
        &format!("/admin/users/{bob}/reset-code"),
        &bot.token,
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "a bot cannot enrol a factor");
}

#[tokio::test]
async fn a_moderator_below_administrator_is_not_asked_for_a_factor() {
    let (store, auth, _guard) = new_store("slimm-totp-elevated-mod").await;
    let router = app(store.clone(), auth.clone());
    let (_admin_token, admin_id) = member(&store, &auth, "alice").await;
    let hash = auth.hash_password(PASSWORD.to_owned()).await.unwrap();
    let carol = store.create_account("carol", "carol", &hash).await.unwrap();
    let carol_token = store
        .open_session(carol.id, "cli")
        .await
        .unwrap()
        .access_token;
    let role = store
        .create_role("mods", Permissions::BAN_MEMBERS, false)
        .await
        .unwrap();
    store.assign_role(carol.id, role).await.unwrap();
    let dave = store.create_account("dave", "dave", &hash).await.unwrap();
    store
        .set_totp_policy(TotpPolicy::RequiredForElevated)
        .await
        .unwrap();
    let _ = admin_id;

    let (status, _) = status_and_error(
        &router,
        "PUT",
        &format!("/members/{}/removal", dave.id),
        &carol_token,
        Some(json!({})),
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
}
