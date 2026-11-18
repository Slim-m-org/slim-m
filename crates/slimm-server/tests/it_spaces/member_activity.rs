// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `GET /members/activity`: each member's newest post, for the role editor's add list.

use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::permissions::Permissions;
use uuid::Uuid;

use crate::support;
use support::app::{TestApp, register_account};

async fn post(app: &TestApp, token: &str, channel: &str, content: &str) -> i64 {
    let (status, body) = app
        .call(
            "POST",
            &format!("/channels/{channel}/messages"),
            token,
            Some(json!({ "id": Uuid::now_v7().to_string(), "content": content })),
        )
        .await;
    assert!(status.is_success(), "send: {status} {body}");
    body["created_at"]
        .as_i64()
        .expect("a sent message has created_at")
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

#[tokio::test]
async fn activity_needs_manage_roles() {
    let app = TestApp::start("slimm-member-activity-test").await;
    let (status, _) = app
        .call("GET", "/members/activity", &app.member.token, None)
        .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
}
