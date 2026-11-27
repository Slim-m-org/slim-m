// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A live heartbeat ends the moment what would close a socket happens: its session signed out,
//! the member removed from the Space, or the account deleted. It never waits out its ttl.

use std::time::Duration;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::ids::UserId;
use tower::ServiceExt;

use crate::support;
use support::app::request_authed as request;

struct World {
    state: AppState,
    admin: (String, UserId),
    bob: (String, UserId),
    watcher: String,
    _guard: support::TestDbGuard,
}

async fn world() -> World {
    let (store, guard) = support::new_store("slimm-presence-heartbeat-ends").await;
    let state = support::app::builder(store.clone()).hub(Hub::new()).build();
    let hash = Auth::new(2)
        .unwrap()
        .hash_password("hunter2hunter2".to_owned())
        .await
        .unwrap();
    let admin = store.create_account("root", "Root", &hash).await.unwrap();
    store.bootstrap_deployment(admin.id).await.unwrap();
    let bob = store.create_account("bob", "Bob", &hash).await.unwrap();
    let watcher = store.create_account("eve", "Eve", &hash).await.unwrap();
    let token = async |id| store.open_session(id, "cli").await.unwrap().access_token;
    World {
        admin: (token(admin.id).await, admin.id),
        bob: (token(bob.id).await, bob.id),
        watcher: token(watcher.id).await,
        state,
        _guard: guard,
    }
}

async fn call(state: &AppState, req: Request<Body>) -> StatusCode {
    http::router(state.clone())
        .oneshot(req)
        .await
        .unwrap()
        .status()
}

async fn status_of(w: &World, target: UserId) -> Value {
    let response = http::router(w.state.clone())
        .oneshot(request(
            "GET",
            &format!("/presence?ids={target}"),
            &w.watcher,
            None,
        ))
        .await
        .unwrap();
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    serde_json::from_slice::<Value>(&bytes).unwrap()[0]["status"].clone()
}

async fn start_beat(w: &World) {
    let body = json!({"activity": {"type": "playing", "title": "Chess"}, "ttl_seconds": 300});
    let status = call(
        &w.state,
        request("PUT", "/presence/heartbeat", &w.bob.0, Some(body)),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(status_of(w, w.bob.1).await, "online");
}

async fn offline_soon(w: &World) {
    for _ in 0..40 {
        if !w.state.hub.presence().is_connected(w.bob.1) {
            return;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    panic!("the heartbeat outlived its session, with 300s of ttl left");
}

#[tokio::test]
async fn signing_out_ends_the_heartbeat() {
    let w = world().await;
    start_beat(&w).await;
    let status = call(&w.state, request("POST", "/auth/logout", &w.bob.0, None)).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    offline_soon(&w).await;
}

#[tokio::test]
async fn removing_the_member_ends_the_heartbeat() {
    let w = world().await;
    start_beat(&w).await;
    let uri = format!("/members/{}/removal", w.bob.1);
    let status = call(&w.state, request("PUT", &uri, &w.admin.0, Some(json!({})))).await;
    assert!(status.is_success(), "{status}");
    offline_soon(&w).await;
}

#[tokio::test]
async fn deleting_the_account_ends_the_heartbeat() {
    let w = world().await;
    start_beat(&w).await;
    let body = json!({"password": "hunter2hunter2"});
    let status = call(
        &w.state,
        request("DELETE", "/account", &w.bob.0, Some(body)),
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    offline_soon(&w).await;
}

#[tokio::test]
async fn another_sessions_sign_out_leaves_the_heartbeat_alone() {
    let w = world().await;
    start_beat(&w).await;
    let other = w.state.store.open_session(w.bob.1, "other").await.unwrap();
    let status = call(
        &w.state,
        request("POST", "/auth/logout", &other.access_token, None),
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(status_of(&w, w.bob.1).await, "online");
}
