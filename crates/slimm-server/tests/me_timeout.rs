// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `/me`'s own timeout fields: the reason a moderator left, self-view only.
//!
//! Split out of `me.rs` rather than added to it - that file was already
//! within a handful of lines of the 500-line hard ceiling; see MOD6.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
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

async fn register(app: &Router, username: &str) -> (String, String) {
    register_with_code(app, username, None).await
}

/// A second (and later) account: the deployment is claimed by the first
/// registration and defaults to `invite`, so anyone after that needs a code
/// from an existing member - here, minted by `host`'s own token.
async fn register_second(app: &Router, host: &str, username: &str) -> (String, String) {
    let created = app
        .clone()
        .oneshot(request("POST", "/invites", Some(host), Some(json!({}))))
        .await
        .unwrap();
    let code = json_body(created).await["code"]
        .as_str()
        .unwrap()
        .to_owned();
    register_with_code(app, username, Some(&code)).await
}

async fn register_with_code(
    app: &Router,
    username: &str,
    invite_code: Option<&str>,
) -> (String, String) {
    let mut body = json!({
        "username": username,
        "display_name": username,
        "password": "hunter2hunter2",
        "device_name": "cli"
    });
    if let Some(code) = invite_code {
        body["invite_code"] = json!(code);
    }
    let response = app
        .clone()
        .oneshot(request("POST", "/auth/register", None, Some(body)))
        .await
        .unwrap();
    let body = json_body(response).await;
    (
        body["access_token"].as_str().unwrap().to_owned(),
        body["user_id"].as_str().unwrap().to_owned(),
    )
}

/// A timed-out member's own `/me` names why: the reason a moderator left is
/// moderation information about the caller, so it belongs in their own self
/// view. See MOD6.
#[tokio::test]
async fn get_me_reports_the_active_timeout_reason() {
    let (store, _guard) = support::new_store("slimm-me-timeout-test").await;
    let app = app(store);
    // The first account to register claims the deployment as its administrator.
    let (admin_token, _admin_id) = register(&app, "alice").await;
    let (bob_token, bob_id) = register_second(&app, &admin_token, "bob").await;

    let timeout = app
        .clone()
        .oneshot(request(
            "PUT",
            &format!("/members/{bob_id}/timeout"),
            Some(&admin_token),
            Some(json!({ "duration_seconds": 3600, "reason": "spamming links" })),
        ))
        .await
        .unwrap();
    assert_eq!(timeout.status(), StatusCode::OK);

    let me = json_body(
        app.clone()
            .oneshot(request("GET", "/me", Some(&bob_token), None))
            .await
            .unwrap(),
    )
    .await;
    assert!(me["timed_out_until"].as_i64().is_some());
    assert_eq!(me["timeout_reason"], "spamming links");
}

/// Not timed out reads as `null`, the same "absent means none" convention
/// `timed_out_until` already follows.
#[tokio::test]
async fn get_me_reports_no_timeout_reason_when_not_timed_out() {
    let (store, _guard) = support::new_store("slimm-me-timeout-test").await;
    let app = app(store);
    let (token, _user_id) = register(&app, "alice").await;

    let me = json_body(
        app.clone()
            .oneshot(request("GET", "/me", Some(&token), None))
            .await
            .unwrap(),
    )
    .await;
    assert!(me["timed_out_until"].is_null());
    assert!(me["timeout_reason"].is_null());
}

/// The privacy boundary this exists for: the reason is self-view only, so
/// another member reading the timed-out member's PUBLIC profile must never
/// see it, even though they may see `timed_out_until` (that a timeout is in
/// force at all).
#[tokio::test]
async fn a_timed_out_members_public_profile_never_shows_the_reason() {
    let (store, _guard) = support::new_store("slimm-me-timeout-test").await;
    let app = app(store);
    let (admin_token, _admin_id) = register(&app, "alice").await;
    let (_bob_token, bob_id) = register_second(&app, &admin_token, "bob").await;

    let timeout = app
        .clone()
        .oneshot(request(
            "PUT",
            &format!("/members/{bob_id}/timeout"),
            Some(&admin_token),
            Some(json!({ "duration_seconds": 3600, "reason": "spamming links" })),
        ))
        .await
        .unwrap();
    assert_eq!(timeout.status(), StatusCode::OK);

    let profile = json_body(
        app.clone()
            .oneshot(request(
                "GET",
                &format!("/users/{bob_id}"),
                Some(&admin_token),
                None,
            ))
            .await
            .unwrap(),
    )
    .await;
    assert!(profile["timed_out_until"].as_i64().is_some());
    assert!(
        profile.get("timeout_reason").is_none(),
        "the public profile must never carry a timeout_reason field"
    );
}
