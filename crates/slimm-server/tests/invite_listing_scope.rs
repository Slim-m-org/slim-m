// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Who may see and revoke which invite.
//!
//! A code is a credential, and a role-granting invite hands its role to
//! whoever spends it. So scoping a listing only by "may issue invites" was an
//! escalation: CREATE_INVITE alone was enough to read back the single-use code
//! an administrator minted to make one specific person a moderator, redeem it
//! first, and take the role. MANAGE_ROLES is the bit that draws the line,
//! because minting such an invite already requires it.
//!
//! Its own file rather than another module in `invites.rs`, which is at its
//! recorded file-budget ceiling, and which `invite_usability.rs` and
//! `invite_redemption_idempotency.rs` already set the precedent for splitting.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::store::Store;
use tower::ServiceExt;

mod support;

use support::app::{json_body, request_authed as request};

/// An admin (via the bootstrap claim) and an ordinary member, with a live
/// router over both.
async fn fixture() -> (Store, Router, String, String, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new("slimm-invite-scope-test");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    let store = Store::new(pool);
    let auth = Auth::new(2).unwrap();
    let hash = auth
        .hash_password("hunter2hunter2".to_owned())
        .await
        .unwrap();
    let admin = store.create_account("admin", "Admin", &hash).await.unwrap();
    store.bootstrap_deployment(admin.id).await.unwrap();
    let member = store
        .create_account("member", "Member", &hash)
        .await
        .unwrap();
    let admin_token = store
        .open_session(admin.id, "d")
        .await
        .unwrap()
        .access_token;
    let member_token = store
        .open_session(member.id, "d")
        .await
        .unwrap()
        .access_token;
    let app = support::app::builder(store.clone()).auth(auth).router();
    (store, app, admin_token, member_token, guard)
}

use slimm_server::permissions::Permissions;

async fn grant_member(store: &Store, bits: Permissions) {
    let member = store.find_credentials("member").await.unwrap().unwrap().0;
    let role = store.create_role("granted", bits, false).await.unwrap();
    store.assign_role(member, role).await.unwrap();
}

async fn codes_visible_to(app: &Router, token: &str) -> Vec<String> {
    let response = app
        .clone()
        .oneshot(request("GET", "/invites", token, None))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    json_body(response)
        .await
        .as_array()
        .unwrap()
        .iter()
        .map(|i| i["code"].as_str().unwrap().to_owned())
        .collect()
}

async fn make_invite(app: &Router, token: &str, body: Value) -> String {
    let response = app
        .clone()
        .oneshot(request("POST", "/invites", token, Some(body)))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    json_body(response).await["code"]
        .as_str()
        .unwrap()
        .to_owned()
}

#[tokio::test]
async fn create_invite_alone_cannot_read_back_somebody_elses_code() {
    let (store, app, admin, member, _guard) = fixture().await;
    let role = store
        .create_role("moderator", Permissions::MANAGE_MESSAGES, false)
        .await
        .unwrap();
    grant_member(&store, Permissions::CREATE_INVITE).await;

    // The invite an administrator mints for one specific person.
    let admin_code = make_invite(
        &app,
        &admin,
        json!({"max_uses": 1, "role_grant": role.to_string()}),
    )
    .await;
    let own_code = make_invite(&app, &member, json!({})).await;

    let visible = codes_visible_to(&app, &member).await;
    assert!(
        !visible.contains(&admin_code),
        "a CREATE_INVITE holder must not be handed the code for a role \
         they were never granted; saw {visible:?}"
    );
    assert_eq!(
        visible,
        vec![own_code],
        "they still see their own, which is the whole point of the route"
    );
}

#[tokio::test]
async fn manage_roles_still_sees_every_invite() {
    let (store, app, admin, member, _guard) = fixture().await;
    grant_member(&store, Permissions::CREATE_INVITE).await;
    let admin_code = make_invite(&app, &admin, json!({})).await;
    let member_code = make_invite(&app, &member, json!({})).await;

    let visible = codes_visible_to(&app, &admin).await;
    assert!(
        visible.contains(&admin_code) && visible.contains(&member_code),
        "an administrator manages the deployment's invites, so the \
         scoping must not hide other people's from them: saw {visible:?}"
    );
}

#[tokio::test]
async fn create_invite_alone_cannot_revoke_somebody_elses() {
    let (store, app, admin, member, _guard) = fixture().await;
    grant_member(&store, Permissions::CREATE_INVITE).await;
    let admin_code = make_invite(&app, &admin, json!({})).await;

    let attempt = app
        .clone()
        .oneshot(request(
            "DELETE",
            &format!("/invites/{admin_code}"),
            &member,
            None,
        ))
        .await
        .unwrap();
    // The same answer an unknown code gets, so the route cannot probe for codes.
    assert_eq!(attempt.status(), StatusCode::NOT_FOUND);
    let unknown = app
        .clone()
        .oneshot(request("DELETE", "/invites/zzzzzzzz", &member, None))
        .await
        .unwrap();
    assert_eq!(unknown.status(), attempt.status());
    assert!(
        store.invite_is_usable(&admin_code).await.unwrap(),
        "the answer says nothing, but the invite must be untouched"
    );
}

#[tokio::test]
async fn revoking_your_own_still_works() {
    let (store, app, _admin, member, _guard) = fixture().await;
    grant_member(&store, Permissions::CREATE_INVITE).await;
    let own_code = make_invite(&app, &member, json!({})).await;

    let revoked = app
        .clone()
        .oneshot(request(
            "DELETE",
            &format!("/invites/{own_code}"),
            &member,
            None,
        ))
        .await
        .unwrap();
    assert_eq!(revoked.status(), StatusCode::NO_CONTENT);
    assert!(!store.invite_is_usable(&own_code).await.unwrap());
}
