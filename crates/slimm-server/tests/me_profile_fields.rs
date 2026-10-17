// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `/me`'s pronouns, about and profile colour, split out of `me.rs` to keep
//! that file under the review budget. Same route, same helpers, own file.

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

/// `pronouns`, `about` and `profile_color` ride the same `/me` route,
/// independently of `display_name` and `status_text` and of each other - the
/// same shape `me.rs`'s own `patch_me_sets_the_status_text_and_it_is_durable`
/// covers.
#[tokio::test]
async fn patch_me_sets_pronouns_about_and_colour_and_they_are_durable() {
    let (store, _guard) = support::new_store("slimm-me-profile-fields-test").await;
    let app = app(store);
    let (token, _user_id) = register(&app, "alice").await;

    let response = app
        .clone()
        .oneshot(request(
            "PATCH",
            "/me",
            Some(&token),
            Some(json!({
                "pronouns": "she/her",
                "about": "Maintainer.",
                "profile_color": 2,
            })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let body = json_body(response).await;
    assert_eq!(body["pronouns"], "she/her");
    assert_eq!(body["about"], "Maintainer.");
    assert_eq!(body["profile_color"], 2);

    let me = json_body(
        app.clone()
            .oneshot(request("GET", "/me", Some(&token), None))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(me["pronouns"], "she/her");
    assert_eq!(me["about"], "Maintainer.");
    assert_eq!(me["profile_color"], 2);
}

/// Blank clears `pronouns`/`about` back to `null`, the same convention
/// `status_text` uses.
#[tokio::test]
async fn patch_me_with_blank_pronouns_and_about_clears_them() {
    let (store, _guard) = support::new_store("slimm-me-profile-fields-test").await;
    let app = app(store);
    let (token, _user_id) = register(&app, "alice").await;

    app.clone()
        .oneshot(request(
            "PATCH",
            "/me",
            Some(&token),
            Some(json!({ "pronouns": "she/her", "about": "hi" })),
        ))
        .await
        .unwrap();

    let response = app
        .clone()
        .oneshot(request(
            "PATCH",
            "/me",
            Some(&token),
            Some(json!({ "pronouns": "  ", "about": "  " })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let body = json_body(response).await;
    assert!(body["pronouns"].is_null());
    assert!(body["about"].is_null());
}

#[tokio::test]
async fn patch_me_rejects_pronouns_and_about_over_their_caps() {
    let (store, _guard) = support::new_store("slimm-me-profile-fields-test").await;
    let app = app(store);
    let (token, _user_id) = register(&app, "alice").await;

    let too_long_pronouns = app
        .clone()
        .oneshot(request(
            "PATCH",
            "/me",
            Some(&token),
            Some(json!({ "pronouns": "x".repeat(41) })),
        ))
        .await
        .unwrap();
    assert_eq!(too_long_pronouns.status(), StatusCode::BAD_REQUEST);

    let too_long_about = app
        .clone()
        .oneshot(request(
            "PATCH",
            "/me",
            Some(&token),
            Some(json!({ "about": "x".repeat(191) })),
        ))
        .await
        .unwrap();
    assert_eq!(too_long_about.status(), StatusCode::BAD_REQUEST);
}

/// An index outside the closed colour set is a 400, not clamped or wrapped.
#[tokio::test]
async fn patch_me_rejects_a_profile_colour_out_of_range() {
    let (store, _guard) = support::new_store("slimm-me-profile-fields-test").await;
    let app = app(store);
    let (token, _user_id) = register(&app, "alice").await;

    let response = app
        .clone()
        .oneshot(request(
            "PATCH",
            "/me",
            Some(&token),
            Some(json!({ "profile_color": 6 })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

/// An account that never chose a colour still reads one: a stable default
/// derived from its id, so a card is never colourless.
#[tokio::test]
async fn an_unset_profile_colour_defaults_to_a_stable_value() {
    let (store, _guard) = support::new_store("slimm-me-profile-fields-test").await;
    let app = app(store);
    let (token, _user_id) = register(&app, "alice").await;

    let first = json_body(
        app.clone()
            .oneshot(request("GET", "/me", Some(&token), None))
            .await
            .unwrap(),
    )
    .await;
    let second = json_body(
        app.clone()
            .oneshot(request("GET", "/me", Some(&token), None))
            .await
            .unwrap(),
    )
    .await;
    assert!(first["profile_color"].is_number());
    assert_eq!(first["profile_color"], second["profile_color"]);
}

/// Pronouns and about are public, visible on another member's profile the
/// same way their status line already is.
#[tokio::test]
async fn another_members_pronouns_and_about_are_visible_on_their_public_profile() {
    let (store, _guard) = support::new_store("slimm-me-profile-fields-test").await;
    let app = app(store);
    let (alice_token, alice_id) = register(&app, "alice").await;
    let (bob_token, _bob_id) = register_second(&app, &alice_token, "bob").await;

    app.clone()
        .oneshot(request(
            "PATCH",
            "/me",
            Some(&alice_token),
            Some(json!({ "pronouns": "she/her", "about": "runs the homelab" })),
        ))
        .await
        .unwrap();

    let response = app
        .clone()
        .oneshot(request(
            "GET",
            &format!("/users/{alice_id}"),
            Some(&bob_token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let body = json_body(response).await;
    assert_eq!(body["pronouns"], "she/her");
    assert_eq!(body["about"], "runs the homelab");
}
