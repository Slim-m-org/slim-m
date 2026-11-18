// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `GET /members/activity`: each member's newest post, for the role editor's add list.

use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::permissions::Permissions;
use uuid::Uuid;

use crate::support;
use support::app::{TestApp, register_account};

async fn post(app: &TestApp, token: &str, channel: &str, content: &str) -> i64 {
    sent(app, token, channel, content).await.1
}

/// Sends a message and returns its id and `created_at`.
async fn sent(app: &TestApp, token: &str, channel: &str, content: &str) -> (String, i64) {
    let id = Uuid::now_v7().to_string();
    let (status, body) = app
        .call(
            "POST",
            &format!("/channels/{channel}/messages"),
            token,
            Some(json!({ "id": id, "content": content })),
        )
        .await;
    assert!(status.is_success(), "send: {status} {body}");
    let created_at = body["created_at"]
        .as_i64()
        .expect("a sent message has created_at");
    (id, created_at)
}

/// Opens the thread under `message` in `channel` and returns the thread's channel id.
async fn thread_of(app: &TestApp, token: &str, channel: &str, message: &str) -> String {
    let (status, body) = app
        .call(
            "POST",
            &format!("/channels/{channel}/messages/{message}/thread"),
            token,
            None,
        )
        .await;
    assert!(status.is_success(), "open thread: {status} {body}");
    body["id"].as_str().unwrap().to_owned()
}

fn last_posted(body: &Value, user: &str) -> Option<i64> {
    body.as_array()
        .expect("an array")
        .iter()
        .find(|entry| entry["user_id"] == user)
        .map(|entry| entry["last_posted_at"].as_i64().unwrap())
}

/// The newest post wins, and only channels the caller can view count: a
/// private channel or a DM never shows that somebody is active in it.
#[tokio::test]
async fn activity_is_the_newest_post_the_caller_could_read() {
    let app = TestApp::start("slimm-member-activity-test").await;
    let general = app.general_channel().await;
    let carol = register_account(&app.store, "carol").await;
    let role = app
        .create_role("role managers", Permissions::MANAGE_ROLES.bits())
        .await;
    let (status, _) = app
        .call(
            "PUT",
            &format!("/members/{}/roles/{role}", app.member.id),
            &app.admin.token,
            None,
        )
        .await;
    assert!(status.is_success(), "assign: {status}");
    let (status, secret) = app
        .call(
            "POST",
            "/channels",
            &app.admin.token,
            Some(json!({ "name": "secret", "restricted": true })),
        )
        .await;
    assert!(status.is_success(), "create private channel: {status}");
    let secret = secret["id"].as_str().unwrap().to_owned();

    post(&app, &carol.token, &general, "first").await;
    let newest_public = post(&app, &carol.token, &general, "second").await;
    let (_, dm) = app
        .call(
            "POST",
            &format!("/dms/{}", app.admin.id),
            &carol.token,
            None,
        )
        .await;
    let dm = dm["channel_id"].as_str().unwrap().to_owned();
    post(&app, &carol.token, &dm, "in a dm").await;
    let admin_secret = post(&app, &app.admin.token, &secret, "private").await;

    let (status, body) = app
        .call("GET", "/members/activity", &app.member.token, None)
        .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    let carol_id = carol.id.to_string();
    assert_eq!(last_posted(&body, &carol_id), Some(newest_public));
    assert_eq!(
        last_posted(&body, &app.admin.id.to_string()),
        None,
        "the admin only posted where this caller cannot look"
    );
    assert_eq!(last_posted(&body, &app.member.id.to_string()), None);

    let (_, body) = app
        .call("GET", "/members/activity", &app.admin.token, None)
        .await;
    assert_eq!(
        last_posted(&body, &app.admin.id.to_string()),
        Some(admin_secret),
        "a caller who can view the private channel sees it count"
    );
    assert_eq!(
        last_posted(&body, &carol_id),
        Some(newest_public),
        "a DM never counts, even for an administrator"
    );
}

/// A thread reply counts where its parent message is visible, and only there.
#[tokio::test]
async fn activity_counts_thread_replies_under_visible_channels() {
    let app = TestApp::start("slimm-member-activity-test").await;
    let general = app.general_channel().await;
    let dave = register_account(&app.store, "dave").await;
    let (status, secret) = app
        .call(
            "POST",
            "/channels",
            &app.admin.token,
            Some(json!({ "name": "secret", "restricted": true })),
        )
        .await;
    assert!(status.is_success(), "create private channel: {status}");
    let secret = secret["id"].as_str().unwrap().to_owned();

    let (parent, admin_public) = sent(&app, &app.admin.token, &general, "start here").await;
    let thread = thread_of(&app, &app.admin.token, &general, &parent).await;
    post(&app, &dave.token, &general, "older top-level post").await;
    let reply = post(&app, &dave.token, &thread, "a reply in the thread").await;
    let (hidden_parent, _) = sent(&app, &app.admin.token, &secret, "private start").await;
    let hidden_thread = thread_of(&app, &app.admin.token, &secret, &hidden_parent).await;
    let hidden_reply = post(&app, &app.admin.token, &hidden_thread, "private reply").await;

    let (status, body) = app
        .call("GET", "/members/activity", &app.admin.token, None)
        .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(
        last_posted(&body, &dave.id.to_string()),
        Some(reply),
        "a thread reply is newer than the top-level post"
    );
    assert_eq!(
        last_posted(&body, &app.admin.id.to_string()),
        Some(hidden_reply),
        "a reply under a channel the caller can view counts"
    );

    let role = app
        .create_role("role managers", Permissions::MANAGE_ROLES.bits())
        .await;
    let (status, _) = app
        .call(
            "PUT",
            &format!("/members/{}/roles/{role}", app.member.id),
            &app.admin.token,
            None,
        )
        .await;
    assert!(status.is_success(), "assign: {status}");
    let (_, body) = app
        .call("GET", "/members/activity", &app.member.token, None)
        .await;
    assert_eq!(last_posted(&body, &dave.id.to_string()), Some(reply));
    assert_eq!(
        last_posted(&body, &app.admin.id.to_string()),
        Some(admin_public),
        "a reply under a private channel never counts for someone shut out of it"
    );
}

#[tokio::test]
async fn activity_needs_manage_roles() {
    let app = TestApp::start("slimm-member-activity-test").await;
    let (status, _) = app
        .call("GET", "/members/activity", &app.member.token, None)
        .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
}
