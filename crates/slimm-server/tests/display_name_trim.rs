// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A display name is stored trimmed, the way the other profile text fields are.

use axum::Router;
use axum::http::StatusCode;
use serde_json::json;
use tower::ServiceExt;

mod support;

use support::app::{app, json_body, request};

async fn display_name_after_patch(app: &Router, token: &str, sent: &str) -> String {
    let response = app
        .clone()
        .oneshot(request(
            "PATCH",
            "/me",
            Some(token),
            Some(json!({ "display_name": sent })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    json_body(response).await["display_name"]
        .as_str()
        .unwrap()
        .to_owned()
}

#[tokio::test]
async fn patching_a_padded_display_name_stores_it_trimmed() {
    let (store, _guard) = support::new_store("slimm-display-name-trim").await;
    let app = app(store.clone());
    let account = store
        .create_account("alice", "Alice", "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    let token = store
        .open_session(account.id, "cli")
        .await
        .unwrap()
        .access_token;

    assert_eq!(
        display_name_after_patch(&app, &token, "   bob  ").await,
        "bob"
    );
    let me = app
        .clone()
        .oneshot(request("GET", "/me", Some(&token), None))
        .await
        .unwrap();
    assert_eq!(json_body(me).await["display_name"], "bob");
}

#[tokio::test]
async fn registering_with_a_padded_display_name_stores_it_trimmed() {
    let (store, _guard) = support::new_store("slimm-display-name-trim").await;
    let app = app(store.clone());
    let response = app
        .clone()
        .oneshot(request(
            "POST",
            "/auth/register",
            None,
            Some(json!({
                "username": "alice",
                "password": "correct-horse-battery",
                "display_name": "  Alice ",
                "device_name": "cli",
            })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let token = json_body(response).await["access_token"]
        .as_str()
        .unwrap()
        .to_owned();
    let me = app
        .clone()
        .oneshot(request("GET", "/me", Some(&token), None))
        .await
        .unwrap();
    assert_eq!(json_body(me).await["display_name"], "Alice");
}
