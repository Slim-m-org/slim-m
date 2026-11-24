// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A timeout reaches the routes that check no permission bit: profile text,
//! pictures, presence activity, and minting a bot token.

use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::ids::UserId;
use slimm_server::permissions::Permissions;
use tower::ServiceExt;

use crate::support;
use support::app::{TestApp, json_body_or_null};

const HOUR_MS: i64 = 60 * 60 * 1000;

async fn time_out(t: &TestApp, user: UserId) {
    t.store
        .set_member_timeout(
            user,
            support::totp_clock::now_ms() + HOUR_MS,
            Some("cool off"),
            t.admin.id,
        )
        .await
        .unwrap();
}

fn assert_timed_out(status: StatusCode, body: &Value, what: &str) {
    assert_eq!(status, StatusCode::FORBIDDEN, "{what}: {body}");
    assert_eq!(body["code"], "timed_out", "{what}: {body}");
    assert_eq!(body["timeout_reason"], "cool off", "{what}: {body}");
}

async fn upload(t: &TestApp, uri: &str, token: &str) -> (StatusCode, Value) {
    let request = Request::builder()
        .method("POST")
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .header("content-type", "image/png")
        .body(Body::from(support::images::small_png()))
        .unwrap();
    let response = t.router.clone().oneshot(request).await.unwrap();
    let status = response.status();
    (status, json_body_or_null(response).await)
}

#[tokio::test]
async fn a_timed_out_member_cannot_change_their_profile_or_pictures() {
    let t = TestApp::start("slimm-guard-profile").await;
    time_out(&t, t.member.id).await;
    let token = t.member.token.clone();

    for body in [
        json!({ "display_name": "new name" }),
        json!({ "status_text": "look at me" }),
        json!({ "about": "words" }),
    ] {
        let (status, refused) = t.call("PATCH", "/me", &token, Some(body.clone())).await;
        assert_timed_out(status, &refused, &body.to_string());
    }
    for uri in ["/me/avatar", "/me/banner"] {
        let (status, refused) = upload(&t, uri, &token).await;
        assert_timed_out(status, &refused, uri);
    }
    let (status, _) = t.call("DELETE", "/me/avatar", &token, None).await;
    assert_eq!(
        status,
        StatusCode::NO_CONTENT,
        "taking a picture down stays open"
    );
}

#[tokio::test]
async fn a_timed_out_member_cannot_broadcast_an_activity_but_can_clear_one() {
    let t = TestApp::start("slimm-guard-activity").await;
    let token = t.member.token.clone();
    let activity = json!({ "type": "listening", "title": "Song", "subtitle": "Artist" });
    let (status, _) = t
        .call("PUT", "/presence/activity", &token, Some(activity.clone()))
        .await;
    assert_eq!(status, StatusCode::NO_CONTENT);

    time_out(&t, t.member.id).await;
    let (status, refused) = t
        .call("PUT", "/presence/activity", &token, Some(activity))
        .await;
    assert_timed_out(status, &refused, "an activity");
    let (status, _) = t.call("DELETE", "/presence/activity", &token, None).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
}

#[tokio::test]
async fn a_timed_out_manager_cannot_mint_a_bot_token() {
    let t = TestApp::start("slimm-guard-bots").await;
    let bot = t
        .store
        .create_bot("helper", "helper", Permissions::NONE, t.admin.id)
        .await
        .unwrap();
    time_out(&t, t.admin.id).await;
    let token = t.admin.token.clone();

    let create = json!({ "username": "sockpuppet", "permissions": 0 });
    let (status, refused) = t.call("POST", "/bots", &token, Some(create)).await;
    assert_timed_out(status, &refused, "creating a bot");
    let reissue = format!("/bots/{}/token", bot.bot.user_id);
    let (status, refused) = t.call("POST", &reissue, &token, None).await;
    assert_timed_out(status, &refused, "reissuing a bot token");
    let revoke = format!("/bots/{}/revoke", bot.bot.user_id);
    let (status, _) = t.call("POST", &revoke, &token, None).await;
    assert_eq!(status, StatusCode::NO_CONTENT, "revoking a bot stays open");
}
