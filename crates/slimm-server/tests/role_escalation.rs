// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Escalation the other direction from `roles.rs`: touching a role above
//! your own level rather than granting one.
//!
//! `assign` already refused to grant a role carrying a bit the caller lacks;
//! `unassign`, `update` and `delete` ran no such check before this pass, so a
//! MANAGE_ROLES holder could revoke, depermission or delete a role they
//! could never have granted. Split into its own file because `roles.rs` was
//! already past the file-size budget before this section existed.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::permissions::Permissions;
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::Store;
use tower::ServiceExt;

mod support;

fn app(store: Store) -> Router {
    http::router(AppState {
        store,
        auth: Auth::new(2).unwrap(),
        hub: Hub::new(),
        limiter: RateLimiter::new(),
        push: PushSender::disabled(),
        voice: slimm_server::voice::VoiceService::disabled(),
        media: slimm_server::media::Media::for_tests(),
        gifs: slimm_server::http::gifs::GifSearch::disabled(),
        link_previews: slimm_server::http::link_preview::LinkPreviews::disabled(),
        dock: slimm_server::http::dock::Dock::disabled(),
        code_runner: slimm_server::code_runner::CodeRunner::disabled(),
    })
}

fn request(method: &str, uri: &str, token: Option<&str>, body: Option<Value>) -> Request<Body> {
    let mut builder = Request::builder().method(method).uri(uri);
    if let Some(token) = token {
        builder = builder.header("authorization", format!("Bearer {token}"));
    }
    match body {
        Some(value) => builder
            .header("content-type", "application/json")
            .body(Body::from(value.to_string()))
            .unwrap(),
        None => builder.body(Body::empty()).unwrap(),
    }
}

async fn json_body(response: axum::response::Response) -> Value {
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    serde_json::from_slice(&bytes).unwrap()
}

/// A member with a session, built straight through the store; see
/// `roles.rs`'s identical helper for why not `/auth/register`.
async fn register(store: &Store, username: &str) -> (String, String) {
    let account = store
        .create_account(username, username, "not-a-real-hash")
        .await
        .unwrap();
    // The first account through here claims the deployment.
    store.bootstrap_deployment(account.id).await.unwrap();
    let tokens = store.open_session(account.id, "cli").await.unwrap();
    (tokens.access_token, account.id.to_string())
}

async fn admin_role_id(store: &Store) -> String {
    store
        .list_roles()
        .await
        .unwrap()
        .into_iter()
        .find(|r| r.name == "admin")
        .expect("bootstrap seeds an admin role")
        .id
        .to_string()
}

/// A MANAGE_ROLES holder with no ADMINISTRATOR cannot unassign a role that
/// carries it, even from somebody who is not the deployment's only
/// administrator - the old code let this through (204) because nothing
/// compared the caller against the role at all, not because the target
/// happened to be safe to touch.
#[tokio::test]
async fn cannot_unassign_an_administrator_role_without_holding_it() {
    let (store, _guard) = support::new_store("slimm-role-escalation-test").await;
    let app = app(store.clone());
    let (admin_token, _admin_id) = register(&store, "alice").await;
    let (_carol_token, carol_id) = register(&store, "carol").await;
    let (bob_token, bob_id) = register(&store, "bob").await;
    let admin_role = admin_role_id(&store).await;

    // carol is a second administrator, so this is not the last-admin guard.
    app.clone()
        .oneshot(request(
            "PUT",
            &format!("/members/{carol_id}/roles/{admin_role}"),
            Some(&admin_token),
            None,
        ))
        .await
        .unwrap();

    let manager_role_id = manage_roles_only_role(&app, &admin_token).await;
    app.clone()
        .oneshot(request(
            "PUT",
            &format!("/members/{bob_id}/roles/{manager_role_id}"),
            Some(&admin_token),
            None,
        ))
        .await
        .unwrap();

    let response = app
        .clone()
        .oneshot(request(
            "DELETE",
            &format!("/members/{carol_id}/roles/{admin_role}"),
            Some(&bob_token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
}

/// Same refusal, this time with a second role that also carries
/// ADMINISTRATOR already assigned to the target - so even the most permissive
/// structural reading (plenty of other paths to an administrator left) still
/// cannot explain success, and the escalation guard has to be what refuses
/// it.
#[tokio::test]
async fn cannot_unassign_an_administrator_role_even_with_a_second_admin_role_present() {
    let (store, _guard) = support::new_store("slimm-role-escalation-test").await;
    let app = app(store.clone());
    let (admin_token, admin_id) = register(&store, "alice").await;
    let (bob_token, bob_id) = register(&store, "bob").await;
    let admin_role = admin_role_id(&store).await;

    let second_admin_role_id = second_admin_role(&app, &admin_token).await;
    app.clone()
        .oneshot(request(
            "PUT",
            &format!("/members/{admin_id}/roles/{second_admin_role_id}"),
            Some(&admin_token),
            None,
        ))
        .await
        .unwrap();

    let manager_role_id = manage_roles_only_role(&app, &admin_token).await;
    app.clone()
        .oneshot(request(
            "PUT",
            &format!("/members/{bob_id}/roles/{manager_role_id}"),
            Some(&admin_token),
            None,
        ))
        .await
        .unwrap();

    let response = app
        .clone()
        .oneshot(request(
            "DELETE",
            &format!("/members/{admin_id}/roles/{admin_role}"),
            Some(&bob_token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
}

/// PATCHing a role's permissions down, even all the way to zero, is still a
/// write to a role the caller could not have granted in the first place: it
/// is compared against the role's current bits, not the requested ones,
/// which is the side the old check got backwards.
#[tokio::test]
async fn cannot_patch_a_role_holding_bits_the_caller_lacks_even_down_to_zero() {
    let (store, _guard) = support::new_store("slimm-role-escalation-test").await;
    let app = app(store.clone());
    let (admin_token, _admin_id) = register(&store, "alice").await;
    let (bob_token, bob_id) = register(&store, "bob").await;

    let guarded_role = json_body(
        app.clone()
            .oneshot(request(
                "POST",
                "/roles",
                Some(&admin_token),
                Some(
                    json!({ "name": "moderators", "permissions": Permissions::BAN_MEMBERS.bits() }),
                ),
            ))
            .await
            .unwrap(),
    )
    .await;
    let guarded_role_id = guarded_role["id"].as_str().unwrap().to_owned();

    let manager_role_id = manage_roles_only_role(&app, &admin_token).await;
    app.clone()
        .oneshot(request(
            "PUT",
            &format!("/members/{bob_id}/roles/{manager_role_id}"),
            Some(&admin_token),
            None,
        ))
        .await
        .unwrap();

    let response = app
        .clone()
        .oneshot(request(
            "PATCH",
            &format!("/roles/{guarded_role_id}"),
            Some(&bob_token),
            Some(json!({ "permissions": 0 })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
}

/// Deleting a role is refused the same way, again with a second
/// administrator role present so the structural invariant is not what is
/// doing the refusing.
#[tokio::test]
async fn only_the_administrators_own_bits_let_them_touch_an_administrator_role() {
    let (store, _guard) = support::new_store("slimm-role-escalation-test").await;
    let app = app(store.clone());
    let (admin_token, admin_id) = register(&store, "alice").await;
    let (bob_token, bob_id) = register(&store, "bob").await;

    let second_admin_role_id = second_admin_role(&app, &admin_token).await;
    app.clone()
        .oneshot(request(
            "PUT",
            &format!("/members/{admin_id}/roles/{second_admin_role_id}"),
            Some(&admin_token),
            None,
        ))
        .await
        .unwrap();

    let guarded_role = json_body(
        app.clone()
            .oneshot(request(
                "POST",
                "/roles",
                Some(&admin_token),
                Some(
                    json!({ "name": "server-managers", "permissions": Permissions::MANAGE_SERVER.bits() }),
                ),
            ))
            .await
            .unwrap(),
    )
    .await;
    let guarded_role_id = guarded_role["id"].as_str().unwrap().to_owned();

    let manager_role_id = manage_roles_only_role(&app, &admin_token).await;
    app.clone()
        .oneshot(request(
            "PUT",
            &format!("/members/{bob_id}/roles/{manager_role_id}"),
            Some(&admin_token),
            None,
        ))
        .await
        .unwrap();

    let response = app
        .clone()
        .oneshot(request(
            "DELETE",
            &format!("/roles/{guarded_role_id}"),
            Some(&bob_token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
}

/// Positive control: an administrator is not caught by any of the four
/// refusals above, since their granted set already contains everything a
/// role could carry. The fix is a comparison, not a blanket refusal on the
/// four verbs.
#[tokio::test]
async fn an_administrator_can_still_unassign_an_administrator_role() {
    let (store, _guard) = support::new_store("slimm-role-escalation-test").await;
    let app = app(store.clone());
    let (admin_token, _admin_id) = register(&store, "alice").await;
    let (_bob_token, bob_id) = register(&store, "bob").await;
    let admin_role = admin_role_id(&store).await;

    app.clone()
        .oneshot(request(
            "PUT",
            &format!("/members/{bob_id}/roles/{admin_role}"),
            Some(&admin_token),
            None,
        ))
        .await
        .unwrap();

    let response = app
        .clone()
        .oneshot(request(
            "DELETE",
            &format!("/members/{bob_id}/roles/{admin_role}"),
            Some(&admin_token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);
}

/// Creates a role carrying only MANAGE_ROLES and returns its id, the shape
/// every test above needs for a caller who may manage roles but must not be
/// able to touch one above their level.
async fn manage_roles_only_role(app: &Router, admin_token: &str) -> String {
    let role = json_body(
        app.clone()
            .oneshot(request(
                "POST",
                "/roles",
                Some(admin_token),
                Some(json!({ "name": "manager", "permissions": Permissions::MANAGE_ROLES.bits() })),
            ))
            .await
            .unwrap(),
    )
    .await;
    role["id"].as_str().unwrap().to_owned()
}

/// Creates a second role carrying ADMINISTRATOR and returns its id, so a test
/// can put the deployment in a state no structural guard would refuse.
async fn second_admin_role(app: &Router, admin_token: &str) -> String {
    let role = json_body(
        app.clone()
            .oneshot(request(
                "POST",
                "/roles",
                Some(admin_token),
                Some(
                    json!({ "name": "co-admin", "permissions": Permissions::ADMINISTRATOR.bits() }),
                ),
            ))
            .await
            .unwrap(),
    )
    .await;
    role["id"].as_str().unwrap().to_owned()
}
