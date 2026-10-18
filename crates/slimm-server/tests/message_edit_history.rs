// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `GET /channels/{id}/messages/{id}/history`: every version a message has
//! held, oldest first, ending with its current content. The reconstruction of
//! each version's "became live at" time is the load-bearing logic, so the
//! multi-edit case pins the exact timestamps, not only the contents.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::ids::UserId;
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use tower::ServiceExt;
use uuid::Uuid;

mod support;

use support::app::{app, json_body, request_authed as request};

async fn register(store: &Store, username: &str) -> (String, UserId) {
    let account = store
        .create_account(username, username, "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    let tokens = store.open_session(account.id, "cli").await.unwrap();
    (tokens.access_token, account.id)
}

async fn send(app: &Router, channel: &str, token: &str, content: &str) -> Value {
    let response = app
        .clone()
        .oneshot(request(
            "POST",
            &format!("/channels/{channel}/messages"),
            token,
            Some(json!({ "id": Uuid::now_v7().to_string(), "content": content })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    json_body(response).await
}

async fn edit(app: &Router, channel: &str, message: &str, token: &str, content: &str) -> Value {
    let response = app
        .clone()
        .oneshot(request(
            "PATCH",
            &format!("/channels/{channel}/messages/{message}"),
            token,
            Some(json!({ "content": content })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    json_body(response).await
}

async fn history(
    app: &Router,
    channel: &str,
    message: &str,
    token: &str,
) -> axum::response::Response {
    app.clone()
        .oneshot(request(
            "GET",
            &format!("/channels/{channel}/messages/{message}/history"),
            token,
            None,
        ))
        .await
        .unwrap()
}

/// `@everyone` can view and send; returns (channel id, token).
async fn open_channel(store: &Store) -> (String, String) {
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let (token, _id) = register(store, "alice").await;
    (channel.id.to_string(), token)
}

#[tokio::test]
async fn an_unedited_message_has_a_single_version() {
    let (store, _guard) = support::new_store("slimm-edit-history-test").await;
    let (channel, token) = open_channel(&store).await;
    let app = app(store);

    let sent = send(&app, &channel, &token, "just this once").await;
    let message = sent["id"].as_str().unwrap();
    let created_at = sent["created_at"].as_i64().unwrap();

    let response = history(&app, &channel, message, &token).await;
    assert_eq!(response.status(), StatusCode::OK);
    let versions = json_body(response).await;
    let versions = versions.as_array().unwrap();
    assert_eq!(versions.len(), 1);
    assert_eq!(versions[0]["content"], "just this once");
    assert_eq!(versions[0]["at"], created_at);
}

#[tokio::test]
async fn each_edit_adds_a_version_oldest_first_with_its_own_time() {
    let (store, _guard) = support::new_store("slimm-edit-history-test").await;
    let (channel, token) = open_channel(&store).await;
    let app = app(store);

    let sent = send(&app, &channel, &token, "v1").await;
    let message = sent["id"].as_str().unwrap().to_owned();
    let created_at = sent["created_at"].as_i64().unwrap();

    let first = edit(&app, &channel, &message, &token, "v2").await;
    let edited_at_1 = first["edited_at"].as_i64().unwrap();
    let second = edit(&app, &channel, &message, &token, "v3").await;
    let edited_at_2 = second["edited_at"].as_i64().unwrap();

    let versions = json_body(history(&app, &channel, &message, &token).await).await;
    let versions = versions.as_array().unwrap();
    assert_eq!(versions.len(), 3, "original plus two edits");

    // Contents oldest first, ending with the current text.
    assert_eq!(versions[0]["content"], "v1");
    assert_eq!(versions[1]["content"], "v2");
    assert_eq!(versions[2]["content"], "v3");

    // Each version's `at` is when it became live: created_at, then each edit.
    assert_eq!(versions[0]["at"], created_at);
    assert_eq!(versions[1]["at"], edited_at_1);
    assert_eq!(versions[2]["at"], edited_at_2);
}

#[tokio::test]
async fn an_edit_that_changes_nothing_adds_no_version() {
    let (store, _guard) = support::new_store("slimm-edit-history-test").await;
    let (channel, token) = open_channel(&store).await;
    let app = app(store);

    let sent = send(&app, &channel, &token, "same").await;
    let message = sent["id"].as_str().unwrap().to_owned();
    edit(&app, &channel, &message, &token, "same").await;

    let versions = json_body(history(&app, &channel, &message, &token).await).await;
    assert_eq!(
        versions.as_array().unwrap().len(),
        1,
        "an unchanged edit writes no revision"
    );
}

#[tokio::test]
async fn a_deleted_message_exposes_no_history() {
    let (store, _guard) = support::new_store("slimm-edit-history-test").await;
    let (channel, token) = open_channel(&store).await;
    let app = app(store);

    let sent = send(&app, &channel, &token, "here then gone").await;
    let message = sent["id"].as_str().unwrap().to_owned();
    edit(&app, &channel, &message, &token, "edited before delete").await;
    let deleted = app
        .clone()
        .oneshot(request(
            "DELETE",
            &format!("/channels/{channel}/messages/{message}"),
            &token,
            None,
        ))
        .await
        .unwrap();
    assert_eq!(deleted.status(), StatusCode::NO_CONTENT);

    let response = history(&app, &channel, &message, &token).await;
    assert_eq!(response.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn history_needs_permission_to_view_the_channel() {
    let (store, _guard) = support::new_store("slimm-edit-history-test").await;
    // @everyone gets nothing; alice is granted what she needs so bob cannot view.
    store
        .create_role("everyone", Permissions::NONE, true)
        .await
        .unwrap();
    let poster = store
        .create_role(
            "poster",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            false,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let channel = channel.id.to_string();
    let app = app(store.clone());
    let (alice_token, alice_id) = register(&store, "alice").await;
    store.assign_role(alice_id, poster).await.unwrap();
    let (bob_token, _bob_id) = register(&store, "bob").await;

    let sent = send(&app, &channel, &alice_token, "for viewers only").await;
    let message = sent["id"].as_str().unwrap();

    let refused = history(&app, &channel, message, &bob_token).await;
    assert_eq!(
        refused.status(),
        StatusCode::FORBIDDEN,
        "a member who cannot view the channel cannot read its history"
    );
    let allowed = history(&app, &channel, message, &alice_token).await;
    assert_eq!(allowed.status(), StatusCode::OK);
}

#[tokio::test]
async fn history_for_a_message_in_another_channel_is_not_found() {
    let (store, _guard) = support::new_store("slimm-edit-history-test").await;
    let (channel_a, token) = open_channel(&store).await;
    let channel_b = store
        .create_channel("second", "text")
        .await
        .unwrap()
        .id
        .to_string();
    let app = app(store);

    let sent = send(&app, &channel_a, &token, "lives in a").await;
    let message = sent["id"].as_str().unwrap();

    // Real message id, real channel the caller can view, but not its channel.
    let response = history(&app, &channel_b, message, &token).await;
    assert_eq!(response.status(), StatusCode::NOT_FOUND);
}
