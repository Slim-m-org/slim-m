// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The caller's own stored presence choice is readable from `GET /me` and from
//! nowhere that describes another user.

use axum::Router;
use axum::http::StatusCode;
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use slimm_server::http::{self, AppState};
use slimm_server::store::Store;
use tokio::net::TcpListener;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message as WsMessage;
use tower::ServiceExt;

mod support;

use support::app::{json_body, request};

fn state(store: Store) -> AppState {
    support::app::state(store)
}

fn app(store: Store) -> Router {
    http::router(state(store))
}

async fn register(app: &Router, username: &str) -> (String, String) {
    register_with_code(app, username, None).await
}

/// A second (and later) account: the deployment is claimed by the first
/// registration and defaults to `invite`, so anyone after that needs a code
/// from an existing member - here, minted by `host`'s own token.
async fn register_second(app: &Router, host: &str, username: &str) -> (String, String) {
    let created = app
        .clone()
        .oneshot(request("POST", "/invites", Some(host), Some(json!({}))))
        .await
        .unwrap();
    let code = json_body(created).await["code"]
        .as_str()
        .unwrap()
        .to_owned();
    register_with_code(app, username, Some(&code)).await
}

async fn register_with_code(
    app: &Router,
    username: &str,
    invite_code: Option<&str>,
) -> (String, String) {
    let mut body = json!({
        "username": username,
        "display_name": username,
        "password": "hunter2hunter2",
        "device_name": "cli"
    });
    if let Some(code) = invite_code {
        body["invite_code"] = json!(code);
    }
    let response = app
        .clone()
        .oneshot(request("POST", "/auth/register", None, Some(body)))
        .await
        .unwrap();
    let body = json_body(response).await;
    (
        body["access_token"].as_str().unwrap().to_owned(),
        body["user_id"].as_str().unwrap().to_owned(),
    )
}

async fn get_json(app: &Router, uri: &str, token: &str) -> Value {
    let response = app
        .clone()
        .oneshot(request("GET", uri, Some(token), None))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK, "{uri}");
    json_body(response).await
}

async fn choose(app: &Router, token: &str, visibility: &str) {
    let body = json!({ "visibility": visibility });
    let response = app
        .clone()
        .oneshot(request("PATCH", "/presence", Some(token), Some(body)))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
}

async fn two_members() -> (
    Router,
    (String, String),
    (String, String),
    support::TestDbGuard,
) {
    let (store, guard) = support::new_store("slimm-me-presence").await;
    let app = app(store);
    let alice = register(&app, "alice").await;
    let bob = register_second(&app, &alice.0, "bob").await;
    (app, alice, bob, guard)
}

#[tokio::test]
async fn a_fresh_account_reads_the_default_back() {
    let (app, alice, _bob, _guard) = two_members().await;
    let me = get_json(&app, "/me", &alice.0).await;
    assert_eq!(me["presence_visibility"], "online");
}

#[tokio::test]
async fn each_choice_reads_back_and_a_change_replaces_it() {
    let (app, alice, _bob, _guard) = two_members().await;
    for choice in ["hidden", "away", "dnd", "online", "hidden"] {
        choose(&app, &alice.0, choice).await;
        let me = get_json(&app, "/me", &alice.0).await;
        assert_eq!(me["presence_visibility"], choice);
    }
}

#[tokio::test]
async fn the_choice_is_the_callers_own_never_another_members() {
    let (app, alice, bob, _guard) = two_members().await;
    choose(&app, &alice.0, "hidden").await;
    let bobs = get_json(&app, "/me", &bob.0).await;
    assert_eq!(bobs["presence_visibility"], "online");
}

#[tokio::test]
async fn no_route_describing_another_member_carries_the_choice() {
    let (app, alice, bob, _guard) = two_members().await;
    choose(&app, &alice.0, "hidden").await;
    let routes = [
        format!("/users/{}", alice.1),
        format!("/users?ids={},{}", alice.1, bob.1),
        "/members?limit=50".to_owned(),
        format!("/presence?ids={}", alice.1),
    ];
    for uri in routes {
        let seen = get_json(&app, &uri, &bob.0).await.to_string();
        assert!(!seen.contains("presence_visibility"), "{uri}: {seen}");
        assert!(!seen.contains("hidden"), "{uri}: {seen}");
    }
}

#[tokio::test]
async fn the_frame_other_members_receive_does_not_carry_the_choice() {
    let (store, _guard) = support::new_store("slimm-me-presence").await;
    let app_state = state(store.clone());
    let app = http::router(app_state.clone());
    let alice = register(&app, "alice").await;
    let bob = register_second(&app, &alice.0, "bob").await;
    let bob_ctx = store.authenticate(&bob.0).await.unwrap().unwrap();
    let (ticket, _) = store.mint_ws_ticket(&bob_ctx).await.unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(listener, http::router(app_state))
            .await
            .unwrap()
    });
    let (mut ws, _) = connect_async(format!("ws://{addr}/ws")).await.unwrap();
    let hello = json!({ "type": "hello", "ticket": ticket, "protocol": 1 });
    ws.send(WsMessage::Text(hello.to_string())).await.unwrap();

    choose(&app, &alice.0, "hidden").await;
    let mut frames = Vec::new();
    while let Ok(Some(Ok(WsMessage::Text(text)))) =
        tokio::time::timeout(std::time::Duration::from_millis(500), ws.next()).await
    {
        frames.push(text.to_string());
    }
    assert!(frames.iter().any(|f| f.contains("presence.changed")));
    for frame in frames {
        assert!(!frame.contains("presence_visibility"), "{frame}");
        assert!(!frame.contains("hidden"), "{frame}");
    }
}
