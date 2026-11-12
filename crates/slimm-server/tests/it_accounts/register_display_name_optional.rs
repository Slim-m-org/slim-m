// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Registering without a display name falls back to the username.

use axum::http::StatusCode;
use serde_json::{Value, json};
use tower::ServiceExt;

use crate::support;
use support::app::{app, json_body, request};

/// Registers on a fresh deployment with `extra` merged into the body, and
/// returns the status plus the display name `/me` reports when it succeeded.
async fn register_with(extra: Value) -> (StatusCode, Option<String>) {
    let (store, _guard) = support::new_store("slimm-register-display-name").await;
    let app = app(store);
    let mut body = json!({
        "username": "alice",
        "password": "correct-horse-battery",
        "device_name": "cli",
    });
    body.as_object_mut()
        .unwrap()
        .extend(extra.as_object().unwrap().clone());
    let response = app
        .clone()
        .oneshot(request("POST", "/auth/register", None, Some(body)))
        .await
        .unwrap();
    let status = response.status();
    if status != StatusCode::OK {
        return (status, None);
    }
    let token = json_body(response).await["access_token"]
        .as_str()
        .unwrap()
        .to_owned();
    let me = app
        .oneshot(request("GET", "/me", Some(&token), None))
        .await
        .unwrap();
    let name = json_body(me).await["display_name"]
        .as_str()
        .map(str::to_owned);
    (status, name)
}

#[tokio::test]
async fn an_absent_display_name_defaults_to_the_username() {
    let (status, name) = register_with(json!({})).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(name.as_deref(), Some("alice"));
}

#[tokio::test]
async fn a_blank_display_name_defaults_to_the_username() {
    let (status, name) = register_with(json!({ "display_name": "   " })).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(name.as_deref(), Some("alice"));
}

#[tokio::test]
async fn a_present_display_name_is_kept() {
    let (status, name) = register_with(json!({ "display_name": "Alice A" })).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(name.as_deref(), Some("Alice A"));
}

#[tokio::test]
async fn a_present_display_name_is_still_length_checked() {
    let (status, _) = register_with(json!({ "display_name": "x".repeat(65) })).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
}
