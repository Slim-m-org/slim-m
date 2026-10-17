// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Invite codes are read aloud, so a code typed back in another case still
//! checks, redeems, revokes and signs up (issue 2116).

use axum::http::StatusCode;
use serde_json::json;
use tower::ServiceExt;

mod support;
use support::overwrite_harness::{app, json_body, new_store, register, request};

async fn issue_code(app: &axum::Router, admin: &str) -> String {
    let created = app
        .clone()
        .oneshot(request("POST", "/invites", Some(admin), Some(json!({}))))
        .await
        .unwrap();
    json_body(created).await["code"]
        .as_str()
        .unwrap()
        .to_owned()
}

#[tokio::test]
async fn an_upper_case_code_checks_and_redeems() {
    let (store, _guard) = new_store("slimm-invite-case").await;
    let (admin, _) = register(&store, "admin").await;
    let (member, _) = register(&store, "member").await;
    let app = app(store);
    let shouted = issue_code(&app, &admin).await.to_ascii_uppercase();

    let check = app
        .clone()
        .oneshot(request(
            "GET",
            &format!("/invites/{shouted}/check"),
            None,
            None,
        ))
        .await
        .unwrap();
    assert_eq!(json_body(check).await["usable"], true);

    let redeemed = app
        .oneshot(request(
            "POST",
            &format!("/invites/{shouted}/redeem"),
            Some(&member),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(redeemed.status(), StatusCode::NO_CONTENT);
}

#[tokio::test]
async fn an_upper_case_code_signs_up_and_revokes() {
    let (store, _guard) = new_store("slimm-invite-case-signup").await;
    let (admin, _) = register(&store, "admin").await;
    let app = app(store);
    let shouted = issue_code(&app, &admin).await.to_ascii_uppercase();

    let registered = app
        .clone()
        .oneshot(request(
            "POST",
            "/auth/register",
            None,
            Some(json!({
                "username": "carol",
                "display_name": "Carol",
                "password": "hunter2hunter2",
                "device_name": "cli",
                "invite_code": format!(" {shouted} "),
            })),
        ))
        .await
        .unwrap();
    assert_eq!(registered.status(), StatusCode::OK);

    let revoked = app
        .oneshot(request(
            "DELETE",
            &format!("/invites/{shouted}"),
            Some(&admin),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(revoked.status(), StatusCode::NO_CONTENT);
}
