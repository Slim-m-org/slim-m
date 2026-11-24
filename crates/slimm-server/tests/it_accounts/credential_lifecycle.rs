// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What a password change or reset retires: pending two-factor challenges and
//! every other live reset code, and what a reset code needs from its issuer.

use axum::Router;
use axum::http::StatusCode;
use serde_json::json;
use slimm_server::auth::Auth;
use slimm_server::ids::UserId;
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use slimm_server::totp;
use tower::ServiceExt;
use uuid::Uuid;

use crate::totp_support::{
    PASSWORD, app, enrol_and_confirm, json_body, login_for_challenge, member, new_store, now_ms,
    request, verify,
};

const NEW_PASSWORD: &str = "a-brand-new-password";

async fn issue(router: &Router, admin_token: &str, user_id: &str) -> axum::response::Response {
    router
        .clone()
        .oneshot(request(
            "POST",
            &format!("/admin/users/{user_id}/reset-code"),
            Some(admin_token),
            Some(json!({ "password": PASSWORD })),
        ))
        .await
        .unwrap()
}

async fn issue_code(router: &Router, admin_token: &str, user_id: &str) -> String {
    let response = issue(router, admin_token, user_id).await;
    assert_eq!(response.status(), StatusCode::OK);
    json_body(response).await["code"]
        .as_str()
        .unwrap()
        .to_owned()
}

async fn spend(router: &Router, code: &str) -> StatusCode {
    router
        .clone()
        .oneshot(request(
            "POST",
            "/auth/reset",
            None,
            Some(json!({ "code": code, "new_password": NEW_PASSWORD })),
        ))
        .await
        .unwrap()
        .status()
}

async fn change_password(router: &Router, token: &str, code: Option<&str>) -> StatusCode {
    router
        .clone()
        .oneshot(request(
            "POST",
            "/auth/password",
            Some(token),
            Some(json!({
                "current_password": PASSWORD,
                "new_password": NEW_PASSWORD,
                "code": code,
            })),
        ))
        .await
        .unwrap()
        .status()
}

/// Alice owns the deployment; bob is an ordinary member on it.
struct Space {
    store: Store,
    auth: Auth,
    router: Router,
    alice: String,
    bob: String,
    bob_id: String,
    _guard: crate::support::TestDbGuard,
}

async fn space(prefix: &str) -> Space {
    let (store, auth, guard) = new_store(prefix).await;
    let router = app(store.clone(), auth.clone());
    let (alice, _) = member(&store, &auth, "alice").await;
    let (bob, bob_id) = member(&store, &auth, "bob").await;
    Space {
        store,
        auth,
        router,
        alice,
        bob,
        bob_id,
        _guard: guard,
    }
}

/// Carol holds ADMINISTRATOR through a role, so she can be demoted or removed.
async fn administrator(space: &Space) -> (String, UserId, slimm_server::ids::RoleId) {
    let (token, id) = member(&space.store, &space.auth, "carol").await;
    let id = UserId(Uuid::parse_str(&id).unwrap());
    let role = space
        .store
        .create_role("deputies", Permissions::ADMINISTRATOR, false)
        .await
        .unwrap();
    space.store.assign_role(id, role).await.unwrap();
    (token, id, role)
}

#[tokio::test]
async fn a_challenge_from_before_a_password_change_cannot_be_completed() {
    let s = space("slimm-cred-challenge-change").await;
    let (secret, recovery) = enrol_and_confirm(&s.router, &s.bob).await;
    let challenge = login_for_challenge(&s.router, "bob").await;

    // A recovery code proves the factor here, so the current step stays unspent for the challenge.
    let status = change_password(&s.router, &s.bob, Some(&recovery[0])).await;
    assert_eq!(status, StatusCode::NO_CONTENT);

    let code = totp::code_at(&secret, now_ms()).unwrap();
    assert_eq!(
        verify(&s.router, &challenge, &code).await.status(),
        StatusCode::UNAUTHORIZED,
        "a challenge minted against the old password must not open a session"
    );
}

#[tokio::test]
async fn a_challenge_from_before_a_reset_cannot_be_completed() {
    let s = space("slimm-cred-challenge-reset").await;
    let (secret, _) = enrol_and_confirm(&s.router, &s.bob).await;
    let challenge = login_for_challenge(&s.router, "bob").await;

    let code = issue_code(&s.router, &s.alice, &s.bob_id).await;
    assert_eq!(spend(&s.router, &code).await, StatusCode::NO_CONTENT);

    let totp_code = totp::code_at(&secret, now_ms()).unwrap();
    assert_eq!(
        verify(&s.router, &challenge, &totp_code).await.status(),
        StatusCode::UNAUTHORIZED
    );
}

#[tokio::test]
async fn spending_one_reset_code_retires_the_others() {
    let s = space("slimm-cred-sibling-codes").await;
    let first = issue_code(&s.router, &s.alice, &s.bob_id).await;
    let second = issue_code(&s.router, &s.alice, &s.bob_id).await;

    assert_eq!(spend(&s.router, &second).await, StatusCode::NO_CONTENT);
    assert_eq!(spend(&s.router, &first).await, StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn changing_the_password_retires_outstanding_reset_codes() {
    let s = space("slimm-cred-change-retires-codes").await;
    let code = issue_code(&s.router, &s.alice, &s.bob_id).await;

    assert_eq!(
        change_password(&s.router, &s.bob, None).await,
        StatusCode::NO_CONTENT
    );
    assert_eq!(spend(&s.router, &code).await, StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn removing_the_issuer_retires_their_reset_codes() {
    let s = space("slimm-cred-issuer-removed").await;
    let (carol, carol_id, _) = administrator(&s).await;
    let code = issue_code(&s.router, &carol, &s.bob_id).await;

    let alice_id = s.store.live_user_id_by_username("alice").await.unwrap();
    s.store
        .remove_from_space(carol_id, alice_id.unwrap(), None)
        .await
        .unwrap();
    assert_eq!(spend(&s.router, &code).await, StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn demoting_the_issuer_retires_their_reset_codes() {
    let s = space("slimm-cred-issuer-demoted").await;
    let (carol, carol_id, role) = administrator(&s).await;
    let code = issue_code(&s.router, &carol, &s.bob_id).await;

    s.store.unassign_role(carol_id, role).await.unwrap();
    assert_eq!(spend(&s.router, &code).await, StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn deleting_the_issuer_retires_their_reset_codes() {
    let s = space("slimm-cred-issuer-deleted").await;
    let (carol, carol_id, _) = administrator(&s).await;
    let code = issue_code(&s.router, &carol, &s.bob_id).await;

    s.store.delete_account(carol_id).await.unwrap();
    assert_eq!(spend(&s.router, &code).await, StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn a_code_from_a_standing_administrator_still_works() {
    let s = space("slimm-cred-issuer-standing").await;
    let (carol, _, _) = administrator(&s).await;
    let code = issue_code(&s.router, &carol, &s.bob_id).await;
    assert_eq!(spend(&s.router, &code).await, StatusCode::NO_CONTENT);
}

#[tokio::test]
async fn a_bot_or_webhook_cannot_be_given_a_reset_code() {
    let s = space("slimm-cred-no-bot-codes").await;
    let alice_id = s
        .store
        .live_user_id_by_username("alice")
        .await
        .unwrap()
        .unwrap();
    let bot = s
        .store
        .create_bot("helper", "Helper", Permissions::NONE, alice_id)
        .await
        .unwrap();
    let response = issue(&s.router, &s.alice, &bot.bot.user_id.to_string()).await;
    assert_eq!(response.status(), StatusCode::CONFLICT);

    let channel = s.store.create_channel("alerts", "text").await.unwrap();
    let hook = s
        .store
        .create_webhook(channel.id, "Alerts", alice_id)
        .await
        .unwrap();
    let response = issue(&s.router, &s.alice, &hook.webhook.principal_id.to_string()).await;
    assert_eq!(response.status(), StatusCode::CONFLICT);
}
