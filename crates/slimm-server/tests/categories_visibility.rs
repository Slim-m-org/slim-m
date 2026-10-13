// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A member only learns the categories that hold a channel they can see; a
//! channel manager sees every category, empty ones included.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use tower::ServiceExt;

mod support;
use support::overwrite_harness::{app, json_body, new_store, register, request};

async fn call(app: &Router, method: &str, uri: &str, token: &str, body: Option<Value>) -> Value {
    let response = app
        .clone()
        .oneshot(request(method, uri, Some(token), body))
        .await
        .unwrap();
    assert!(
        response.status().is_success(),
        "{method} {uri}: {}",
        response.status()
    );
    if response.status() == StatusCode::NO_CONTENT {
        return Value::Null;
    }
    json_body(response).await
}

async fn category(app: &Router, admin: &str, name: &str) -> String {
    let created = call(
        app,
        "POST",
        "/categories",
        admin,
        Some(json!({"name": name})),
    )
    .await;
    created["id"].as_str().unwrap().to_owned()
}

async fn names(app: &Router, token: &str) -> Vec<String> {
    call(app, "GET", "/categories", token, None)
        .await
        .as_array()
        .unwrap()
        .iter()
        .map(|c| c["name"].as_str().unwrap().to_owned())
        .collect()
}

#[tokio::test]
async fn a_member_sees_only_categories_with_a_channel_they_can_view() {
    let (store, _guard) = new_store("slimm-categories-visibility").await;
    let app = app(store.clone());
    let (admin, _) = register(&store, "owner").await;
    let (member, _) = register(&store, "member").await;

    let staff = category(&app, &admin, "staff").await;
    let open = category(&app, &admin, "open").await;
    category(&app, &admin, "empty").await;
    let private = json!({"name": "staff-chat", "restricted": true, "category_id": staff});
    call(&app, "POST", "/channels", &admin, Some(private)).await;
    let public = json!({"name": "lobby", "category_id": open});
    call(&app, "POST", "/channels", &admin, Some(public)).await;

    let seen = names(&app, &member).await;
    assert!(seen.contains(&"open".to_owned()), "{seen:?}");
    assert!(
        !seen.contains(&"staff".to_owned()),
        "a private category's name leaked: {seen:?}"
    );
    assert!(!seen.contains(&"empty".to_owned()), "{seen:?}");

    let managed = names(&app, &admin).await;
    for name in ["staff", "open", "empty"] {
        assert!(
            managed.contains(&name.to_owned()),
            "{name} missing for a manager: {managed:?}"
        );
    }
}
