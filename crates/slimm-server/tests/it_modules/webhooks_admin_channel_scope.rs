// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Managing a webhook follows its channel: MANAGE_SERVER alone does not reach a
//! channel its holder cannot see or post in, and nobody points one at a direct message.

use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::permissions::Permissions;

use crate::support;
use support::app::{TestApp, register_account};

/// A deployment whose `member` holds MANAGE_SERVER and nothing else beyond `@everyone`.
async fn with_a_manager(prefix: &str) -> TestApp {
    let app = TestApp::start(prefix).await;
    let role = app
        .create_role("managers", Permissions::MANAGE_SERVER.bits())
        .await;
    let grant = format!("/members/{}/roles/{role}", app.member.id);
    let (status, body) = app.call("PUT", &grant, &app.admin.token, None).await;
    assert!(status.is_success(), "grant: {status} {body}");
    app
}

async fn private_channel(app: &TestApp) -> String {
    let body = json!({"name": "staff", "restricted": true});
    let (status, channel) = app
        .call("POST", "/channels", &app.admin.token, Some(body))
        .await;
    assert!(status.is_success(), "{status} {channel}");
    channel["id"].as_str().unwrap().to_owned()
}

async fn mint(app: &TestApp, token: &str, channel: &str) -> (StatusCode, Value) {
    let body = json!({"channel_id": channel, "label": "deploys"});
    app.call("POST", "/webhooks", token, Some(body)).await
}

async fn deliver(app: &TestApp, path: &str) -> StatusCode {
    let body = json!({"content": "shipped"});
    app.call("POST", path, "", Some(body)).await.0
}

#[tokio::test]
async fn a_manager_cannot_mint_a_webhook_into_a_channel_they_cannot_see() {
    let app = with_a_manager("slimm-webhook-scope-mint").await;
    let hidden = private_channel(&app).await;
    let nowhere = uuid::Uuid::now_v7().to_string();

    let refused = mint(&app, &app.member.token, &hidden).await;
    let unknown = mint(&app, &app.member.token, &nowhere).await;
    assert_eq!(refused.0, StatusCode::NOT_FOUND, "{}", refused.1);
    assert_eq!(refused, unknown, "a hidden channel answers like no channel");

    let general = app.general_channel().await;
    let (status, body) = mint(&app, &app.member.token, &general).await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
}

#[tokio::test]
async fn a_manager_neither_sees_nor_touches_a_webhook_in_a_channel_they_cannot_see() {
    let app = with_a_manager("slimm-webhook-scope-hidden").await;
    let hidden = private_channel(&app).await;
    let (status, minted) = mint(&app, &app.admin.token, &hidden).await;
    assert_eq!(status, StatusCode::CREATED, "{minted}");
    let id = minted["webhook"]["id"].as_str().unwrap();
    let path = minted["delivery_path"].as_str().unwrap();
    let manager = &app.member.token;

    let (status, listed) = app.call("GET", "/webhooks", manager, None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        listed,
        json!([]),
        "the manager's list names a hidden channel"
    );

    let rename = json!({"label": "mine now"});
    let attempts = [
        ("PATCH", format!("/webhooks/{id}"), Some(rename)),
        ("POST", format!("/webhooks/{id}/rotate"), None),
        ("POST", format!("/webhooks/{id}/revoke"), None),
    ];
    for (method, uri, body) in attempts {
        let (status, body) = app.call(method, &uri, manager, body).await;
        assert_eq!(status, StatusCode::NOT_FOUND, "{method} {uri}: {body}");
    }

    assert_eq!(deliver(&app, path).await, StatusCode::NO_CONTENT);
    let (_, listed) = app.call("GET", "/webhooks", &app.admin.token, None).await;
    assert_eq!(listed[0]["label"], "deploys");
}

#[tokio::test]
async fn a_manager_who_cannot_post_in_a_channel_gets_no_credential_that_can() {
    let app = with_a_manager("slimm-webhook-scope-read-only").await;
    let news = app.create_channel("news").await;
    let (_, roles) = app.call("GET", "/roles", &app.admin.token, None).await;
    let everyone = roles
        .as_array()
        .unwrap()
        .iter()
        .find(|role| role["is_everyone"] == true)
        .expect("@everyone")["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let deny = json!({"deny": Permissions::SEND_MESSAGES.bits()});
    let overwrite = format!("/channels/{news}/overwrites/role/{everyone}");
    let (status, body) = app
        .call("PUT", &overwrite, &app.admin.token, Some(deny))
        .await;
    assert!(status.is_success(), "{status} {body}");

    let (status, minted) = mint(&app, &app.admin.token, &news).await;
    assert_eq!(status, StatusCode::CREATED, "{minted}");
    let id = minted["webhook"]["id"].as_str().unwrap();
    let manager = &app.member.token;

    assert_eq!(mint(&app, manager, &news).await.0, StatusCode::FORBIDDEN);
    let rotate = format!("/webhooks/{id}/rotate");
    let (status, _) = app.call("POST", &rotate, manager, None).await;
    assert_eq!(status, StatusCode::FORBIDDEN);

    let (_, listed) = app.call("GET", "/webhooks", manager, None).await;
    assert_eq!(listed[0]["id"], id, "a channel they can see is listed");
}

#[tokio::test]
async fn nobody_points_a_webhook_at_a_direct_message() {
    let app = TestApp::start("slimm-webhook-scope-dm").await;
    let carol = register_account(&app.store, "carol").await;
    let open = format!("/dms/{}", carol.id);
    let (_, theirs) = app.call("POST", &open, &app.member.token, None).await;
    let (_, mine) = app.call("POST", &open, &app.admin.token, None).await;

    for dm in [&theirs, &mine] {
        let channel = dm["channel_id"].as_str().expect("a direct message");
        let (status, body) = mint(&app, &app.admin.token, channel).await;
        assert_eq!(status, StatusCode::NOT_FOUND, "{body}");
    }
}
