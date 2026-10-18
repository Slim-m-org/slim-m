// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The caller's own profile: reading it with effective base permissions, and
//! updating the display name and/or status text.

use axum::Router;
use axum::http::StatusCode;
use serde_json::json;
use slimm_server::permissions::Permissions;
use tower::ServiceExt;

mod support;

use support::app::{app, json_body, request};

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

/// `/me` echoes the caller's own profile plus their effective base
/// permissions, so a client can decide which actions to show.
#[tokio::test]
async fn get_me_returns_profile_and_base_permissions() {
    let (store, _guard) = support::new_store("slimm-me-test").await;
    let app = app(store);
    // No role pre-created: the first account to register claims the
    // unclaimed deployment and is granted an administrator role.
    let (token, user_id) = register(&app, "alice").await;

    let response = app
        .clone()
        .oneshot(request("GET", "/me", Some(&token), None))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let body = json_body(response).await;

    assert_eq!(body["id"], user_id);
    assert_eq!(body["username"], "alice");
    assert_eq!(body["display_name"], "alice");

    // The first account to register claims the deployment and becomes an
    // administrator, so its base permissions carry ADMINISTRATOR.
    let permissions = body["permissions"].as_i64().unwrap();
    assert_eq!(
        permissions & Permissions::ADMINISTRATOR.bits(),
        Permissions::ADMINISTRATOR.bits()
    );
}

#[tokio::test]
async fn get_me_requires_authentication() {
    let (store, _guard) = support::new_store("slimm-me-test").await;
    let app = app(store);

    let response = app
        .clone()
        .oneshot(request("GET", "/me", None, None))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn patch_me_updates_the_display_name() {
    let (store, _guard) = support::new_store("slimm-me-test").await;
    let app = app(store);
    let (token, _user_id) = register(&app, "alice").await;

    let response = app
        .clone()
        .oneshot(request(
            "PATCH",
            "/me",
            Some(&token),
            Some(json!({ "display_name": "Alice In Wonderland" })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let body = json_body(response).await;
    assert_eq!(body["display_name"], "Alice In Wonderland");
    // The username is unchanged; this endpoint has no field for it at all.
    assert_eq!(body["username"], "alice");

    // The change is durable: a fresh read shows it too.
    let me = json_body(
        app.clone()
            .oneshot(request("GET", "/me", Some(&token), None))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(me["display_name"], "Alice In Wonderland");
}

/// A `username` field in the body has no effect: the endpoint has no such
/// field, so it cannot be used to rename the account.
#[tokio::test]
async fn patch_me_cannot_change_the_username() {
    let (store, _guard) = support::new_store("slimm-me-test").await;
    let app = app(store);
    let (token, _user_id) = register(&app, "alice").await;

    let response = app
        .clone()
        .oneshot(request(
            "PATCH",
            "/me",
            Some(&token),
            Some(json!({ "display_name": "Alice", "username": "totally-different" })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let body = json_body(response).await;
    assert_eq!(body["username"], "alice");
}

#[tokio::test]
async fn patch_me_rejects_a_whitespace_only_name() {
    let (store, _guard) = support::new_store("slimm-me-test").await;
    let app = app(store);
    let (token, _user_id) = register(&app, "alice").await;

    let response = app
        .clone()
        .oneshot(request(
            "PATCH",
            "/me",
            Some(&token),
            Some(json!({ "display_name": "   " })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn patch_me_rejects_a_name_that_is_too_long() {
    let (store, _guard) = support::new_store("slimm-me-test").await;
    let app = app(store);
    let (token, _user_id) = register(&app, "alice").await;

    let response = app
        .clone()
        .oneshot(request(
            "PATCH",
            "/me",
            Some(&token),
            Some(json!({ "display_name": "x".repeat(65) })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

/// `status_text` rides the same route as `display_name`, independently: a
/// caller may set either alone, or both together.
#[tokio::test]
async fn patch_me_sets_the_status_text_and_it_is_durable() {
    let (store, _guard) = support::new_store("slimm-me-test").await;
    let app = app(store);
    let (token, _user_id) = register(&app, "alice").await;

    let response = app
        .clone()
        .oneshot(request(
            "PATCH",
            "/me",
            Some(&token),
            Some(json!({ "status_text": "in a meeting" })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let body = json_body(response).await;
    assert_eq!(body["status_text"], "in a meeting");
    // The display name was never touched by this request.
    assert_eq!(body["display_name"], "alice");

    let me = json_body(
        app.clone()
            .oneshot(request("GET", "/me", Some(&token), None))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(me["status_text"], "in a meeting");
}

/// A missing `status_text` field leaves it exactly as it was, the same
/// "absent means untouched" contract `display_name` gets.
#[tokio::test]
async fn patch_me_with_only_a_display_name_leaves_the_status_text_alone() {
    let (store, _guard) = support::new_store("slimm-me-test").await;
    let app = app(store);
    let (token, _user_id) = register(&app, "alice").await;

    app.clone()
        .oneshot(request(
            "PATCH",
            "/me",
            Some(&token),
            Some(json!({ "status_text": "afk" })),
        ))
        .await
        .unwrap();

    let response = app
        .clone()
        .oneshot(request(
            "PATCH",
            "/me",
            Some(&token),
            Some(json!({ "display_name": "Alice" })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let body = json_body(response).await;
    assert_eq!(body["display_name"], "Alice");
    assert_eq!(body["status_text"], "afk");
}

/// A blank status clears it back to `null` rather than storing an empty
/// string - the same convention a channel's topic already uses.
#[tokio::test]
async fn patch_me_with_a_blank_status_clears_it() {
    let (store, _guard) = support::new_store("slimm-me-test").await;
    let app = app(store);
    let (token, _user_id) = register(&app, "alice").await;

    app.clone()
        .oneshot(request(
            "PATCH",
            "/me",
            Some(&token),
            Some(json!({ "status_text": "afk" })),
        ))
        .await
        .unwrap();

    let response = app
        .clone()
        .oneshot(request(
            "PATCH",
            "/me",
            Some(&token),
            Some(json!({ "status_text": "   " })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let body = json_body(response).await;
    assert!(body["status_text"].is_null());
}

#[tokio::test]
async fn patch_me_rejects_a_status_over_eighty_characters() {
    let (store, _guard) = support::new_store("slimm-me-test").await;
    let app = app(store);
    let (token, _user_id) = register(&app, "alice").await;

    let response = app
        .clone()
        .oneshot(request(
            "PATCH",
            "/me",
            Some(&token),
            Some(json!({ "status_text": "x".repeat(81) })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

/// Neither field present is refused rather than silently doing nothing - the
/// same "at least one, absent means untouched" contract
/// `UpdateChannelRequest` already enforces for its own name and topic.
#[tokio::test]
async fn patch_me_with_neither_field_is_rejected() {
    let (store, _guard) = support::new_store("slimm-me-test").await;
    let app = app(store);
    let (token, _user_id) = register(&app, "alice").await;

    let response = app
        .clone()
        .oneshot(request("PATCH", "/me", Some(&token), Some(json!({}))))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

/// A member's status is public, visible to anyone else on the deployment
/// the same way their display name is - shown in the member pane under
/// their name.
#[tokio::test]
async fn another_members_status_text_is_visible_on_their_public_profile() {
    let (store, _guard) = support::new_store("slimm-me-test").await;
    let app = app(store);
    let (alice_token, alice_id) = register(&app, "alice").await;
    let (bob_token, _bob_id) = register_second(&app, &alice_token, "bob").await;

    app.clone()
        .oneshot(request(
            "PATCH",
            "/me",
            Some(&alice_token),
            Some(json!({ "status_text": "on holiday" })),
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
    assert_eq!(body["status_text"], "on holiday");
}

// `pronouns`/`about`/`profile_color` tests live in me_profile_fields.rs.
