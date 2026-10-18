// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The shared `support::app` harness drives the real router end to end.

use axum::http::StatusCode;
use serde_json::json;

mod support;

use support::app::TestApp;

#[tokio::test]
async fn deployment_fixture_has_an_admin_who_can_make_channels_and_roles() {
    let app = TestApp::start("slimm-test-app-harness").await;

    let channel = app.create_channel("notes").await;
    let role = app.create_role("helpers", 0).await;

    let (status, channels) = app.call("GET", "/channels", &app.admin.token, None).await;
    assert_eq!(status, StatusCode::OK);
    let ids: Vec<_> = channels
        .as_array()
        .unwrap()
        .iter()
        .map(|c| c["id"].as_str().unwrap().to_owned())
        .collect();
    assert!(ids.contains(&channel));
    assert!(!role.is_empty());
}

#[tokio::test]
async fn member_cannot_use_admin_only_routes() {
    let app = TestApp::start("slimm-test-app-harness-member").await;

    let (status, _) = app
        .call(
            "POST",
            "/roles",
            &app.member.token,
            Some(json!({ "name": "nope", "permissions": 0 })),
        )
        .await;

    assert_eq!(status, StatusCode::FORBIDDEN);
}
