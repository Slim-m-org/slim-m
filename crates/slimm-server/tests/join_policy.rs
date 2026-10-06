// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The deployment's join policy: who may create an account.
//!
//! Invite-only is the default and the behaviour that shipped, so the tests
//! that matter are the ones proving an upgrade does not open a Space by
//! itself, that opening it is gated on MANAGE_SERVER, and that an open Space
//! still honours a code's role grant rather than ignoring it.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::{JoinPolicy, Store};
use tower::ServiceExt;

mod support;

async fn new_store() -> (Store, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new("slimm-join-policy");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool), guard)
}

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
        Some(body) => builder
            .header("content-type", "application/json")
            .body(Body::from(body.to_string()))
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

async fn signup(app: &Router, username: &str, code: Option<&str>) -> axum::response::Response {
    let mut body = json!({
        "username": username,
        "display_name": username,
        "password": "hunter2hunter2",
        "device_name": "cli"
    });
    if let Some(code) = code {
        body["invite_code"] = json!(code);
    }
    app.clone()
        .oneshot(request("POST", "/auth/register", None, Some(body)))
        .await
        .unwrap()
}

/// Registers the account that claims the deployment and returns its token.
async fn claim(app: &Router) -> String {
    let response = signup(app, "alice", None).await;
    assert_eq!(response.status(), StatusCode::OK);
    json_body(response).await["access_token"]
        .as_str()
        .unwrap()
        .to_owned()
}

#[tokio::test]
async fn a_fresh_deployment_is_invite_only() {
    let (store, _guard) = new_store().await;
    assert_eq!(store.join_policy().await.unwrap(), JoinPolicy::Invite);

    let app = app(store);
    claim(&app).await;

    // The second account has no code, and the default must refuse it.
    let response = signup(&app, "bob", None).await;
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn an_open_deployment_takes_an_account_with_no_code() {
    let (store, _guard) = new_store().await;
    let app = app(store.clone());
    let admin = claim(&app).await;

    let patched = app
        .clone()
        .oneshot(request(
            "PATCH",
            "/space/settings",
            Some(&admin),
            Some(json!({"join_policy": "open"})),
        ))
        .await
        .unwrap();
    assert_eq!(patched.status(), StatusCode::OK);

    let response = signup(&app, "bob", None).await;
    assert_eq!(response.status(), StatusCode::OK);
}

#[tokio::test]
async fn an_open_deployment_still_applies_a_codes_role_grant() {
    let (store, _guard) = new_store().await;
    let app = app(store.clone());
    let admin = claim(&app).await;
    store.set_join_policy(JoinPolicy::Open).await.unwrap();

    // Built through the store: `POST /invites` exposes max_uses and
    // expires_at only, so a role-granting code has no HTTP surface yet.
    let admin_id = store.find_credentials("alice").await.unwrap().unwrap().0;
    let role = store
        .create_role(
            "moderator",
            slimm_server::permissions::Permissions::from_bits(0),
            false,
        )
        .await
        .unwrap();
    // `/members` reports role names, not ids.
    let invite = store
        .create_invite(admin_id, Some(role), None, None)
        .await
        .unwrap();

    // Open means a code is optional, never ignored: presenting one still
    // spends it and still applies what it grants.
    let response = signup(&app, "bob", Some(&invite.code)).await;
    assert_eq!(response.status(), StatusCode::OK);

    let listed = app
        .oneshot(request("GET", "/members", Some(&admin), None))
        .await
        .unwrap();
    let members = json_body(listed).await;
    let bob = members
        .as_array()
        .unwrap()
        .iter()
        .find(|m| m["username"] == "bob")
        .expect("bob is a member")
        .clone();
    assert_eq!(bob["roles"][0], "moderator");
}

#[tokio::test]
async fn an_open_deployment_still_refuses_a_bad_code() {
    let (store, _guard) = new_store().await;
    let app = app(store.clone());
    claim(&app).await;
    store.set_join_policy(JoinPolicy::Open).await.unwrap();

    let response = signup(&app, "bob", Some("not-a-real-code")).await;
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn changing_the_policy_needs_manage_server() {
    let (store, _guard) = new_store().await;
    let app = app(store.clone());
    let admin = claim(&app).await;
    store.set_join_policy(JoinPolicy::Open).await.unwrap();

    let response = signup(&app, "bob", None).await;
    assert_eq!(response.status(), StatusCode::OK);
    let bob = json_body(response).await["access_token"]
        .as_str()
        .unwrap()
        .to_owned();

    for (method, body) in [
        ("GET", None),
        ("PATCH", Some(json!({"join_policy": "invite"}))),
    ] {
        let response = app
            .clone()
            .oneshot(request(method, "/space/settings", Some(&bob), body))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::FORBIDDEN, "{method}");
    }

    // And the admin can still do both, so the refusal above is the bit and
    // not the route being broken.
    let response = app
        .oneshot(request("GET", "/space/settings", Some(&admin), None))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
}

#[tokio::test]
async fn an_unknown_policy_is_refused_rather_than_coerced() {
    let (store, _guard) = new_store().await;
    let app = app(store.clone());
    let admin = claim(&app).await;

    let response = app
        .clone()
        .oneshot(request(
            "PATCH",
            "/space/settings",
            Some(&admin),
            Some(json!({"join_policy": "everyone"})),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);

    // Refused means unchanged, not "defaulted to something".
    assert_eq!(store.join_policy().await.unwrap(), JoinPolicy::Invite);
}

#[tokio::test]
async fn version_reports_whether_a_code_is_needed() {
    let (store, _guard) = new_store().await;
    let app = app(store.clone());

    let before = json_body(
        app.clone()
            .oneshot(request("GET", "/version", None, None))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(before["invite_required"], true);

    store.set_join_policy(JoinPolicy::Open).await.unwrap();

    let after = json_body(
        app.oneshot(request("GET", "/version", None, None))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(after["invite_required"], false);
}

#[tokio::test]
async fn version_reports_whether_the_deployment_is_claimed() {
    let (store, _guard) = new_store().await;
    let app = app(store);

    let version = || async {
        json_body(
            app.clone()
                .oneshot(request("GET", "/version", None, None))
                .await
                .unwrap(),
        )
        .await
    };
    assert_eq!(version().await["claimed"], false);

    claim(&app).await;
    assert_eq!(version().await["claimed"], true);
}

#[tokio::test]
async fn a_patch_writes_only_the_fields_it_carries() {
    let (store, _guard) = new_store().await;
    let app = app(store.clone());
    let admin = claim(&app).await;
    store.set_join_policy(JoinPolicy::Open).await.unwrap();

    let totp_only = app
        .clone()
        .oneshot(request(
            "PATCH",
            "/space/settings",
            Some(&admin),
            Some(json!({"totp_policy": "optional"})),
        ))
        .await
        .unwrap();
    assert_eq!(totp_only.status(), StatusCode::OK);
    let body = json_body(totp_only).await;
    assert_eq!(body["join_policy"], "open");
    assert_eq!(body["totp_policy"], "optional");
    assert_eq!(store.join_policy().await.unwrap(), JoinPolicy::Open);

    let empty = app
        .oneshot(request(
            "PATCH",
            "/space/settings",
            Some(&admin),
            Some(json!({})),
        ))
        .await
        .unwrap();
    assert_eq!(empty.status(), StatusCode::BAD_REQUEST);
}
