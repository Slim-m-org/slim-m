// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Integration tests for the join policy on `POST /auth/register`.
//!
//! The invite system existed for a whole phase while `register` never consulted
//! it, so anyone who found a deployment's address could create an account on it
//! and read every channel `@everyone` could see. These tests pin the two halves
//! of the fix: an unclaimed deployment still lets its first account in with no
//! code, and a claimed one accepts nobody without a usable one.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::ids::UserId;
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

fn signup(username: &str, invite_code: Option<&str>) -> Value {
    let mut body = json!({
        "username": username,
        "display_name": username,
        "password": "hunter2hunter2",
        "device_name": "cli",
    });
    if let Some(code) = invite_code {
        body["invite_code"] = json!(code);
    }
    body
}

/// Claims a fresh deployment with an admin account and returns its token.
async fn claimed() -> (Store, Router, String, support::TestDbGuard) {
    let (store, guard) = support::new_store("slimm-register-gate").await;
    let app = app(store.clone());
    let first = app
        .clone()
        .oneshot(request(
            "POST",
            "/auth/register",
            None,
            Some(signup("admin", None)),
        ))
        .await
        .unwrap();
    assert_eq!(
        first.status(),
        StatusCode::OK,
        "the first account claims an unclaimed deployment with no code"
    );
    let token = json_body(first).await["access_token"]
        .as_str()
        .unwrap()
        .to_owned();
    (store, app, token, guard)
}

async fn mint_invite(app: &Router, admin: &str, body: Value) -> String {
    let created = app
        .clone()
        .oneshot(request("POST", "/invites", Some(admin), Some(body)))
        .await
        .unwrap();
    assert_eq!(created.status(), StatusCode::OK);
    json_body(created).await["code"]
        .as_str()
        .unwrap()
        .to_owned()
}

#[tokio::test]
async fn a_claimed_deployment_refuses_a_registration_with_no_invite() {
    let (_store, app, _admin, _guard) = claimed().await;

    let refused = app
        .clone()
        .oneshot(request(
            "POST",
            "/auth/register",
            None,
            Some(signup("stranger", None)),
        ))
        .await
        .unwrap();
    assert_eq!(refused.status(), StatusCode::BAD_REQUEST);
    let body = json_body(refused).await;
    assert_eq!(
        body["error"],
        "an invite code is required to join this server"
    );

    // An empty or whitespace-only code is not a code.
    for blank in ["", "   "] {
        let refused = app
            .clone()
            .oneshot(request(
                "POST",
                "/auth/register",
                None,
                Some(signup("stranger", Some(blank))),
            ))
            .await
            .unwrap();
        assert_eq!(
            refused.status(),
            StatusCode::BAD_REQUEST,
            "{blank:?} must not pass as an invite code"
        );
    }
}

#[tokio::test]
async fn a_usable_invite_lets_someone_in_and_is_spent_by_the_signup() {
    let (store, app, admin, _guard) = claimed().await;
    let code = mint_invite(&app, &admin, json!({ "max_uses": 1 })).await;

    let joined = app
        .clone()
        .oneshot(request(
            "POST",
            "/auth/register",
            None,
            Some(signup("invited", Some(&code))),
        ))
        .await
        .unwrap();
    assert_eq!(joined.status(), StatusCode::OK);
    let tokens = json_body(joined).await;
    assert!(tokens["access_token"].as_str().is_some());

    // The signup spent the use, so the same code cannot let a second person in.
    assert!(!store.invite_is_usable(&code).await.unwrap());
    let second = app
        .clone()
        .oneshot(request(
            "POST",
            "/auth/register",
            None,
            Some(signup("gatecrasher", Some(&code))),
        ))
        .await
        .unwrap();
    assert_eq!(second.status(), StatusCode::BAD_REQUEST);
    assert_eq!(
        json_body(second).await["error"],
        "that invite cannot be used"
    );
}

#[tokio::test]
async fn an_unusable_code_is_refused_and_leaves_the_username_free() {
    let (store, app, admin, _guard) = claimed().await;
    let revoked = mint_invite(&app, &admin, json!({})).await;
    let gone = app
        .clone()
        .oneshot(request(
            "DELETE",
            &format!("/invites/{revoked}"),
            Some(&admin),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(gone.status(), StatusCode::NO_CONTENT);

    for code in ["nosuchcode", revoked.as_str()] {
        let refused = app
            .clone()
            .oneshot(request(
                "POST",
                "/auth/register",
                None,
                Some(signup("hopeful", Some(code))),
            ))
            .await
            .unwrap();
        assert_eq!(refused.status(), StatusCode::BAD_REQUEST);
        // One answer for never-existed and revoked alike, so registration
        // cannot be used to mine which codes are real.
        assert_eq!(
            json_body(refused).await["error"],
            "that invite cannot be used"
        );
    }

    // The rejected attempts must not have left half an account behind: the
    // username is still free for whoever actually holds a code.
    let code = mint_invite(&app, &admin, json!({})).await;
    let accepted = app
        .clone()
        .oneshot(request(
            "POST",
            "/auth/register",
            None,
            Some(signup("hopeful", Some(&code))),
        ))
        .await
        .unwrap();
    assert_eq!(
        accepted.status(),
        StatusCode::OK,
        "a failed invite must roll its account insert back"
    );
    assert!(store.find_credentials("hopeful").await.unwrap().is_some());
}

/// The HTTP create-invite route does not expose `role_grant` yet, so the
/// role-carrying invite is built through the store the way an admin console
/// eventually will.
#[tokio::test]
async fn an_invite_that_grants_a_role_applies_it_at_signup() {
    let (store, app, _admin, _guard) = claimed().await;
    let role = store
        .create_role("moderator", Permissions::MANAGE_MESSAGES, false)
        .await
        .unwrap();
    let issuer = store.find_credentials("admin").await.unwrap().unwrap().0;
    let invite = store
        .create_invite(issuer, Some(role), None, None)
        .await
        .unwrap();

    let joined = app
        .clone()
        .oneshot(request(
            "POST",
            "/auth/register",
            None,
            Some(signup("mod", Some(&invite.code))),
        ))
        .await
        .unwrap();
    assert_eq!(joined.status(), StatusCode::OK);
    let raw = json_body(joined).await["user_id"]
        .as_str()
        .unwrap()
        .to_owned();
    let user_id = UserId(uuid::Uuid::parse_str(&raw).unwrap());

    let permissions = store.base_permissions(user_id).await.unwrap();
    assert!(
        permissions.contains(Permissions::MANAGE_MESSAGES),
        "the invite's role must land on the account it let in"
    );
}

#[tokio::test]
async fn a_failed_signup_does_not_spend_the_invite() {
    let (store, app, admin, _guard) = claimed().await;
    let code = mint_invite(&app, &admin, json!({ "max_uses": 1 })).await;

    // Taking a username that already exists fails after the code has been
    // presented; the code must survive for its rightful holder.
    let taken = app
        .clone()
        .oneshot(request(
            "POST",
            "/auth/register",
            None,
            Some(signup("admin", Some(&code))),
        ))
        .await
        .unwrap();
    assert_eq!(taken.status(), StatusCode::CONFLICT);
    assert!(
        store.invite_is_usable(&code).await.unwrap(),
        "a username collision must not burn the invite"
    );

    let joined = app
        .clone()
        .oneshot(request(
            "POST",
            "/auth/register",
            None,
            Some(signup("someone", Some(&code))),
        ))
        .await
        .unwrap();
    assert_eq!(joined.status(), StatusCode::OK);
}

/// `@everyone` and `@here` are reserved so a mention can never collide with a
/// real account. Covered by a unit test on `validate_username`, but nothing
/// posted the names over the router - a regression that stopped `register`
/// calling the validator would pass that unit test (TEST11).
#[tokio::test]
async fn a_reserved_username_is_refused_at_registration() {
    let (store, _guard) = support::new_store("slimm-register-gate").await;
    let app = app(store.clone());

    // Reserved case-insensitively, and refused before any invite/claim check, so even an unclaimed deployment answers 400 rather than claiming the name.
    for name in ["everyone", "here", "EVERYONE", "Here"] {
        let response = app
            .clone()
            .oneshot(request(
                "POST",
                "/auth/register",
                None,
                Some(signup(name, None)),
            ))
            .await
            .unwrap();
        assert_eq!(
            response.status(),
            StatusCode::BAD_REQUEST,
            "registering {name:?} must be refused as reserved"
        );
    }

    // And the deployment stays unclaimed: a refused reserved name is a no-op.
    assert!(
        !store.is_bootstrapped().await.unwrap(),
        "a refused reserved registration must not claim the deployment"
    );
}
