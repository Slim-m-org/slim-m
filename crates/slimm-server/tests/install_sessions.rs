// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A client that sends a stable `install_id` at sign-in keeps one session row
//! per install: signing in again replaces the previous session instead of
//! adding a row to the devices list. A client that sends none behaves as it
//! always did.

use std::time::Duration;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::http::{self, AppState};
use slimm_server::ids::DeviceId;
use slimm_server::store::Store;
use tokio::net::TcpListener;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message as WsMessage;
use tower::ServiceExt;

mod support;

type Client =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

const PASSWORD: &str = "correct horse battery";

async fn setup() -> (AppState, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new("slimm-install-sessions");
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

async fn serve(state: AppState) -> std::net::SocketAddr {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(listener, http::router(state)).await.unwrap();
    });
    addr
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

async fn sign_in(state: &AppState, device: &str, install: Option<&str>) -> Value {
    let mut payload = json!({
        "username": "alice",
        "password": PASSWORD,
        "device_name": device,
        "client_kind": "desktop",
    });
    if let Some(install) = install {
        payload["install_id"] = json!(install);
    }
    let response = http::router(state.clone())
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/auth/login")
                .header("content-type", "application/json")
                .body(Body::from(payload.to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    serde_json::from_slice(&bytes).unwrap()
}

async fn refresh_status(state: &AppState, refresh_token: &str) -> StatusCode {
    http::router(state.clone())
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/auth/refresh")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({ "refresh_token": refresh_token }).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap()
        .status()
}

async fn listed(state: &AppState) -> Vec<slimm_server::store::Device> {
    let user = state
        .store
        .find_credentials("alice")
        .await
        .unwrap()
        .unwrap()
        .0;
    state
        .store
        .list_devices(user, DeviceId::generate())
        .await
        .unwrap()
}

#[tokio::test]
async fn the_same_install_signing_in_twice_leaves_one_session() {
    let (state, _guard) = setup().await;
    account(&state, "alice").await;
    let first = sign_in(&state, "Linux - fedora", Some("install-aaaaaaaa")).await;
    let second = sign_in(&state, "Linux - fedora", Some("install-aaaaaaaa")).await;

    assert_eq!(listed(&state).await.len(), 1);
    let old = first["refresh_token"].as_str().unwrap();
    let new = second["refresh_token"].as_str().unwrap();
    assert_eq!(refresh_status(&state, old).await, StatusCode::UNAUTHORIZED);
    assert_eq!(refresh_status(&state, new).await, StatusCode::OK);
    let stale = state
        .store
        .authenticate(first["access_token"].as_str().unwrap())
        .await
        .unwrap();
    assert!(
        stale.is_none(),
        "the replaced session's access token is dead"
    );
}

#[tokio::test]
async fn a_different_install_adds_a_row() {
    let (state, _guard) = setup().await;
    account(&state, "alice").await;
    sign_in(&state, "Linux - fedora", Some("install-aaaaaaaa")).await;
    sign_in(&state, "Linux - fedora", Some("install-bbbbbbbb")).await;
    assert_eq!(listed(&state).await.len(), 2);
}

#[tokio::test]
async fn the_same_install_id_on_another_account_is_not_the_same_device() {
    let (state, _guard) = setup().await;
    account(&state, "alice").await;
    account(&state, "bob").await;
    sign_in(&state, "Linux - fedora", Some("install-aaaaaaaa")).await;
    let response = http::router(state.clone())
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/auth/login")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "username": "bob", "password": PASSWORD,
                        "device_name": "Linux - fedora", "install_id": "install-aaaaaaaa",
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(listed(&state).await.len(), 1, "alice keeps her own row");
}

#[tokio::test]
async fn a_client_with_no_install_id_still_adds_a_row_per_sign_in() {
    let (state, _guard) = setup().await;
    account(&state, "alice").await;
    sign_in(&state, "Linux - fedora", None).await;
    sign_in(&state, "Linux - fedora", None).await;
    assert_eq!(listed(&state).await.len(), 2);
}

#[tokio::test]
async fn a_malformed_install_id_is_refused() {
    let (state, _guard) = setup().await;
    account(&state, "alice").await;
    let response = http::router(state.clone())
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/auth/login")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "username": "alice", "password": PASSWORD,
                        "device_name": "x", "install_id": "bad id with spaces",
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

async fn ticket_for(state: &AppState, tokens: &Value) -> String {
    let ctx = state
        .store
        .authenticate(tokens["access_token"].as_str().unwrap())
        .await
        .unwrap()
        .unwrap();
    state.store.mint_ws_ticket(&ctx).await.unwrap().0
}

#[tokio::test]
async fn the_alert_fires_for_a_new_install_and_not_for_a_known_one() {
    let (state, _guard) = setup().await;
    account(&state, "alice").await;
    let phone = sign_in(&state, "Pixel", Some("install-pixel0000")).await;
    let addr = serve(state.clone()).await;
    let mut watcher = connect(addr, &ticket_for(&state, &phone).await).await;

    sign_in(&state, "Laptop", Some("install-laptop000")).await;
    assert_eq!(alerts(&mut watcher).await.len(), 1, "a new install alerts");

    sign_in(&state, "Laptop (renamed)", Some("install-laptop000")).await;
    assert!(
        alerts(&mut watcher).await.is_empty(),
        "a re-login of a known install stays quiet"
    );

    sign_in(&state, "Tablet", Some("install-tablet000")).await;
    assert_eq!(alerts(&mut watcher).await.len(), 1);
}
