// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Signing in on a device the account has not used before tells its other
//! connected devices, and stays quiet for the sign-in itself, a known device,
//! the first device, and a login loop.

use std::time::Duration;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::http::{self, AppState};
use slimm_server::hub::Event;
use slimm_server::ids::{DeviceId, UserId};
use slimm_server::store::Store;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message as WsMessage;
use tower::ServiceExt;

use crate::support;
use support::ws::{Client, serve};

const PASSWORD: &str = "correct horse battery";

async fn setup() -> (AppState, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new("slimm-new-device-sign-in");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let store = Store::new(db::connect(&config).await.expect("connect + migrate"));
    let state = support::app::state(store);
    (state, guard)
}

async fn account(state: &AppState, name: &str) {
    let hash = state.auth.hash_password(PASSWORD.to_owned()).await.unwrap();
    state.store.create_account(name, name, &hash).await.unwrap();
}

async fn login(state: &AppState, name: &str, device: &str, kind: &str) -> String {
    login_as_device(state, name, device, kind).await.0
}

/// Signs in carrying an install id, which is what makes a device recognisable on its next sign-in.
async fn login_install(state: &AppState, name: &str, device: &str, kind: &str, install: &str) {
    let response = http::router(state.clone())
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/auth/login")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "username": name,
                        "password": PASSWORD,
                        "device_name": device,
                        "client_kind": kind,
                        "install_id": install,
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
}

/// Signs in over REST and returns the new device's ws ticket and id.
async fn login_as_device(
    state: &AppState,
    name: &str,
    device: &str,
    kind: &str,
) -> (String, UserId, DeviceId) {
    let response = http::router(state.clone())
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/auth/login")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "username": name,
                        "password": PASSWORD,
                        "device_name": device,
                        "client_kind": kind,
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    let body: Value = serde_json::from_slice(&bytes).unwrap();
    let ctx = state
        .store
        .authenticate(body["access_token"].as_str().unwrap())
        .await
        .unwrap()
        .unwrap();
    (
        state.store.mint_ws_ticket(&ctx).await.unwrap().0,
        ctx.user_id,
        ctx.device_id,
    )
}

async fn connect(addr: std::net::SocketAddr, ticket: &str) -> Client {
    let (mut ws, _response) = connect_async(format!("ws://{addr}/ws")).await.unwrap();
    ws.send(WsMessage::Text(
        json!({ "type": "hello", "ticket": ticket, "protocol": 1 }).to_string(),
    ))
    .await
    .unwrap();
    while let Some(Ok(WsMessage::Text(text))) = ws.next().await {
        let frame: Value = serde_json::from_str(text.as_str()).unwrap();
        if frame["type"] == "hello" {
            return ws;
        }
    }
    panic!("no hello ack");
}

/// Every `device.signed_in` frame that arrives before the socket goes quiet.
async fn alerts(ws: &mut Client) -> Vec<Value> {
    let mut found = Vec::new();
    while let Ok(Some(Ok(WsMessage::Text(text)))) =
        tokio::time::timeout(Duration::from_millis(500), ws.next()).await
    {
        let frame: Value = serde_json::from_str(text.as_str()).unwrap();
        if frame["type"] == "device.signed_in" {
            found.push(frame);
        }
    }
    found
}

#[tokio::test]
async fn an_unfamiliar_device_alerts_the_others_but_not_itself() {
    let (state, _guard) = setup().await;
    account(&state, "alice").await;
    let first = login(&state, "alice", "Pixel", "android").await;
    let addr = serve(state.clone()).await;
    let mut phone = connect(addr, &first).await;

    let laptop_ticket = login(&state, "alice", "Laptop", "desktop").await;
    let _laptop = connect(addr, &laptop_ticket).await;

    let seen = alerts(&mut phone).await;
    assert_eq!(seen.len(), 1);
    assert_eq!(seen[0]["device_name"], "Laptop");
    assert_eq!(seen[0]["client_kind"], "desktop");
    assert!(seen[0]["signed_in_at"].as_i64().unwrap() > 0);
}

/// The sign-in's own socket cannot exist yet when the alert is published, so
/// the alert is published by hand for a device whose socket is already open.
#[tokio::test]
async fn a_device_does_not_hear_an_alert_naming_itself() {
    let (state, _guard) = setup().await;
    account(&state, "alice").await;
    let (first, ..) = login_as_device(&state, "alice", "Pixel", "android").await;
    let (second, user_id, laptop_id) = login_as_device(&state, "alice", "Laptop", "desktop").await;
    let addr = serve(state.clone()).await;
    let mut phone = connect(addr, &first).await;
    let mut laptop = connect(addr, &second).await;

    state.hub.publish(Event::NewDeviceSignIn {
        user_id,
        device_id: laptop_id,
        device_name: "Laptop".to_owned(),
        client_kind: Some("desktop".to_owned()),
        signed_in_at: 1,
    });

    assert_eq!(alerts(&mut phone).await.len(), 1, "sanity: others hear it");
    assert!(alerts(&mut laptop).await.is_empty());
}

#[tokio::test]
async fn a_relogin_of_a_known_install_stays_quiet() {
    let (state, _guard) = setup().await;
    account(&state, "alice").await;
    let install = "0192b7a0-0000-7000-8000-000000000001";
    login_install(&state, "alice", "Pixel", "android", install).await;
    let first = login(&state, "alice", "Laptop", "desktop").await;
    let addr = serve(state.clone()).await;
    let mut laptop = connect(addr, &first).await;

    login_install(&state, "alice", "Pixel", "android", install).await;

    assert!(alerts(&mut laptop).await.is_empty());
}

/// The name and kind a client reports are chosen by whoever signs in, so matching an old row
/// by them must not silence the alert.
#[tokio::test]
async fn a_sign_in_reusing_a_known_name_and_kind_without_an_install_still_alerts() {
    let (state, _guard) = setup().await;
    account(&state, "alice").await;
    let first = login(&state, "alice", "iPhone", "ios").await;
    let addr = serve(state.clone()).await;
    let mut phone = connect(addr, &first).await;

    login(&state, "alice", "iPhone", "ios").await;

    assert_eq!(alerts(&mut phone).await.len(), 1);
}

#[tokio::test]
async fn another_account_never_hears_it() {
    let (state, _guard) = setup().await;
    account(&state, "alice").await;
    account(&state, "bob").await;
    let alice = login(&state, "alice", "Pixel", "android").await;
    let bob = login(&state, "bob", "Pixel", "android").await;
    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice).await;
    let mut bob_ws = connect(addr, &bob).await;

    login(&state, "alice", "Laptop", "desktop").await;

    assert_eq!(alerts(&mut alice_ws).await.len(), 1);
    assert!(alerts(&mut bob_ws).await.is_empty());
}

#[tokio::test]
async fn a_login_loop_is_rate_limited() {
    let (state, _guard) = setup().await;
    account(&state, "alice").await;
    let first = login(&state, "alice", "Pixel", "android").await;
    let addr = serve(state.clone()).await;
    let mut phone = connect(addr, &first).await;

    for n in 0..6 {
        login(&state, "alice", &format!("Device {n}"), "web").await;
    }

    let seen = alerts(&mut phone).await;
    assert!(!seen.is_empty());
    assert!(seen.len() < 6, "the burst budget caps the notices");
}
