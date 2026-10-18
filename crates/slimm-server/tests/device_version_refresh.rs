// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A refresh carries the app's current kind and version, so the devices list
//! follows an app update. It used to keep the version a session signed in
//! with forever: a 0.107 client showed as 0.86.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use tower::ServiceExt;

mod support;

use support::app::{app, json_body};

fn post(uri: &str, body: Value) -> Request<Body> {
    Request::builder()
        .method("POST")
        .uri(uri)
        .header("content-type", "application/json")
        .body(Body::from(body.to_string()))
        .unwrap()
}

async fn my_device(app: &Router, access_token: &str) -> Value {
    let response = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/devices")
                .header("authorization", format!("Bearer {access_token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    json_body(response).await.as_array().unwrap()[0].clone()
}

async fn refresh(app: &Router, refresh_token: &str, extra: Value) -> Value {
    let mut body = json!({ "refresh_token": refresh_token });
    body.as_object_mut()
        .unwrap()
        .extend(extra.as_object().unwrap().clone());
    let response = app
        .clone()
        .oneshot(post("/auth/refresh", body))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    json_body(response).await
}

#[tokio::test]
async fn a_refresh_updates_the_reported_version_and_a_bare_one_keeps_it() {
    let (store, _guard) = support::new_store("slimm-device-version").await;
    let auth = Auth::new(2).unwrap();
    let hash = auth
        .hash_password("hunter2hunter2".to_owned())
        .await
        .unwrap();
    let alice = store.create_account("alice", "Alice", &hash).await.unwrap();
    let signed_in = store
        .open_session_as(
            alice.id,
            "Linux (fedora)",
            Some("desktop"),
            Some("0.86.0"),
            None,
        )
        .await
        .unwrap();
    let app = app(store);

    let updated = refresh(
        &app,
        &signed_in.refresh_token,
        json!({ "client_kind": "desktop", "client_version": "0.107.0" }),
    )
    .await;
    let access = updated["access_token"].as_str().unwrap();
    assert_eq!(my_device(&app, access).await["client_version"], "0.107.0");

    let bare = refresh(&app, updated["refresh_token"].as_str().unwrap(), json!({})).await;
    let device = my_device(&app, bare["access_token"].as_str().unwrap()).await;
    assert_eq!(device["client_version"], "0.107.0");
    assert_eq!(device["client_kind"], "desktop");
}

#[tokio::test]
async fn a_refresh_refuses_a_spoofed_version_like_sign_in_does() {
    let (store, _guard) = support::new_store("slimm-device-version-bad").await;
    let auth = Auth::new(2).unwrap();
    let hash = auth
        .hash_password("hunter2hunter2".to_owned())
        .await
        .unwrap();
    let alice = store.create_account("alice", "Alice", &hash).await.unwrap();
    let signed_in = store.open_session(alice.id, "phone").await.unwrap();

    let response = app(store)
        .oneshot(post(
            "/auth/refresh",
            json!({ "refresh_token": signed_in.refresh_token, "client_version": "1\u{202E}0" }),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}
