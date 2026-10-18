// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The optional welcome message posted when a member joins.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};

mod support;

use support::app::call_as as call;
use support::overwrite_harness::{app, general_channel_id, new_store, register};

async fn join(
    router: &Router,
    store: &slimm_server::store::Store,
    root: &str,
    name: &str,
) -> (String, String) {
    let (_, invite) = call(router, "POST", "/invites", root, Some(json!({}))).await;
    let code = invite["code"].as_str().unwrap().to_owned();
    let (token, _) = register(store, name).await;
    let (status, _) = call(
        router,
        "POST",
        &format!("/invites/{code}/redeem"),
        &token,
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    (code, token)
}

async fn messages(router: &Router, root: &str, channel: &str) -> Vec<Value> {
    let (_, body) = call(
        router,
        "GET",
        &format!("/channels/{channel}/messages"),
        root,
        None,
    )
    .await;
    body.as_array().cloned().unwrap_or_default()
}

#[tokio::test]
async fn nothing_is_posted_until_an_admin_turns_the_welcome_on() {
    let (store, _guard) = new_store("slimm-welcome-off").await;
    let (root, _) = register(&store, "root").await;
    let general = general_channel_id(&store).await;
    let router = app(store.clone());

    let (_, settings) = call(&router, "GET", "/space/settings", &root, None).await;
    assert_eq!(settings["welcome_enabled"], false);
    join(&router, &store, &root, "sam").await;
    assert!(messages(&router, &root, &general).await.is_empty());
}

#[tokio::test]
async fn a_join_posts_one_welcome_naming_the_member_and_the_space() {
    let (store, _guard) = new_store("slimm-welcome-on").await;
    let (root, _) = register(&store, "root").await;
    let general = general_channel_id(&store).await;
    let router = app(store.clone());

    let (status, settings) = call(
        &router,
        "PATCH",
        "/space/settings",
        &root,
        Some(json!({
            "welcome_enabled": true,
            "welcome_channel_id": general,
            "welcome_message": "Hello {user}, welcome to {space}",
        })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{settings}");
    assert_eq!(settings["welcome_channel_id"], general);

    let (code, token) = join(&router, &store, &root, "sam").await;
    let posted = messages(&router, &root, &general).await;
    assert_eq!(posted.len(), 1, "{posted:?}");
    let content = posted[0]["content"].as_str().unwrap();
    assert!(content.starts_with("Hello @sam, welcome to "), "{content}");

    // A retried redeem is not a new join.
    let _ = call(
        &router,
        "POST",
        &format!("/invites/{code}/redeem"),
        &token,
        None,
    )
    .await;
    assert_eq!(messages(&router, &root, &general).await.len(), 1);
}

#[tokio::test]
async fn a_welcome_needs_a_text_channel_and_a_message_to_turn_on() {
    let (store, _guard) = new_store("slimm-welcome-validate").await;
    let (root, _) = register(&store, "root").await;
    let general = general_channel_id(&store).await;
    let router = app(store);

    let (status, _) = call(
        &router,
        "PATCH",
        "/space/settings",
        &root,
        Some(json!({"welcome_enabled": true})),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    let (_, voice) = call(
        &router,
        "POST",
        "/channels",
        &root,
        Some(json!({"name": "talk", "kind": "voice"})),
    )
    .await;
    let (status, _) = call(
        &router,
        "PATCH",
        "/space/settings",
        &root,
        Some(json!({"welcome_channel_id": voice["id"]})),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    let too_long = "x".repeat(501);
    let (status, _) = call(
        &router,
        "PATCH",
        "/space/settings",
        &root,
        Some(json!({"welcome_message": too_long})),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    let (status, _) = call(
        &router,
        "PATCH",
        "/space/settings",
        &root,
        Some(json!({"welcome_channel_id": general, "welcome_message": "hi", "welcome_enabled": true})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let (status, cleared) = call(
        &router,
        "PATCH",
        "/space/settings",
        &root,
        Some(json!({"welcome_channel_id": "", "welcome_enabled": false})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert!(cleared["welcome_channel_id"].is_null());
}

#[tokio::test]
async fn only_an_admin_can_change_the_welcome() {
    let (store, _guard) = new_store("slimm-welcome-gate").await;
    let (_root, _) = register(&store, "root").await;
    let (member, _) = register(&store, "member").await;
    let router = app(store);

    let (status, _) = call(
        &router,
        "PATCH",
        "/space/settings",
        &member,
        Some(json!({"welcome_message": "hi"})),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
}
