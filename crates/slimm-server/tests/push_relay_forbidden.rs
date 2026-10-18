// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A relay that answers `forbidden` must show up as a count an admin can scrape.
//!
//! Before this, `dispatch` dropped the status, so a server the shared relay would not deliver
//! for lost its pushes with no trace anywhere.

use std::time::Duration;

use axum::routing::post;
use axum::{Json, Router};
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use crypto_box::SecretKey;
use crypto_box::aead::rand_core::{OsRng, TryRngCore};
use serde_json::{Value, json};
use slimm_server::config::Config;
use slimm_server::hub::Hub;
use slimm_server::permissions::Permissions;
use slimm_server::push::PushSender;
use slimm_server::store::Store;
use tokio::net::TcpListener;
use tower::ServiceExt;

mod support;

fn app(store: Store, push: PushSender) -> Router {
    app_with_voice(
        store,
        push,
        slimm_server::voice::VoiceService::disabled(),
        Hub::new(),
    )
}

fn app_with_voice(
    store: Store,
    push: PushSender,
    voice: slimm_server::voice::VoiceService,
    hub: Hub,
) -> Router {
    support::app::builder(store)
        .hub(hub)
        .push(push)
        .voice(voice)
        .router()
}

fn request(
    method: &str,
    uri: &str,
    token: Option<&str>,
    body: Option<Value>,
) -> axum::http::Request<axum::body::Body> {
    let mut builder = axum::http::Request::builder().method(method).uri(uri);
    if let Some(token) = token {
        builder = builder.header("authorization", format!("Bearer {token}"));
    }
    match body {
        Some(value) => builder
            .header("content-type", "application/json")
            .body(axum::body::Body::from(value.to_string()))
            .unwrap(),
        None => builder.body(axum::body::Body::empty()).unwrap(),
    }
}

/// A member with a session, built straight through the store.
///
/// Deliberately not the `/auth/register` route: joining a claimed deployment
/// is an invite-gated policy decision, and it is pinned by its own tests in
/// `registration_gate.rs`. These tests only need somebody signed in, so going
/// through the store keeps them independent of that policy.
async fn register_user(store: &Store, username: &str) -> String {
    let account = store
        .create_account(username, username, "not-a-real-hash")
        .await
        .unwrap();
    // The first account through here claims the deployment, as a real registration does.
    store.bootstrap_deployment(account.id).await.unwrap();
    store
        .open_session(account.id, "cli")
        .await
        .unwrap()
        .access_token
}

/// Registers a real device keypair for push over HTTP, exactly the request
/// shape a client sends, so what gets sealed downstream is sealed to a key
/// the "device" (this test) actually holds and can unseal. `platform` is
/// "ios" or "android" - [`http::push`](slimm_server)'s `RegisterRequest`
/// accepts nothing else - so the caller picks which of the relay's two
/// platforms this device's real, later-captured entry will exercise.
async fn register_push(app: &Router, token: &str, platform: &str, push_token: &str) -> SecretKey {
    let secret = SecretKey::generate(&mut OsRng.unwrap_err());
    let public = secret.public_key();
    let response = app
        .clone()
        .oneshot(request(
            "PUT",
            "/push",
            Some(token),
            Some(json!({
                "platform": platform,
                "push_token": push_token,
                "voip_push_token": Value::Null,
                "push_public_key": BASE64.encode(public.as_bytes()),
                "include_content": false,
                "include_content_chosen": true,
            })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), axum::http::StatusCode::NO_CONTENT);
    secret
}

async fn seeded_store() -> (Store, slimm_server::ids::ChannelId, support::TestDbGuard) {
    let (store, guard) = support::new_store("slimm-push-forbidden").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    (store, channel.id, guard)
}

async fn spawn_forbidding_relay() -> String {
    let router = Router::new().route(
        "/v1/send",
        post(|Json(body): Json<Value>| async move {
            let results: Vec<Value> = body["messages"]
                .as_array()
                .cloned()
                .unwrap_or_default()
                .iter()
                .map(|m| json!({ "token": m["token"], "status": "forbidden" }))
                .collect();
            Json(json!({ "results": results }))
        }),
    );
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(listener, router).await.unwrap();
    });
    format!("http://{addr}")
}

async fn scrape(app: &Router, token: &str) -> String {
    let response = app
        .clone()
        .oneshot(request("GET", "/metrics", Some(token), None))
        .await
        .unwrap();
    assert_eq!(response.status(), axum::http::StatusCode::OK);
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    String::from_utf8(bytes.to_vec()).unwrap()
}

#[tokio::test]
async fn a_forbidden_relay_result_is_counted_and_shown_to_the_admin() {
    let (store, channel_id, _guard) = seeded_store().await;
    let relay_url = spawn_forbidding_relay().await;
    let push = PushSender::with_debounce_window_ms(
        &Config {
            port: 0,
            database_path: String::new(),
            hash_concurrency: 2,
            push_relay_url: Some(relay_url),
            push_relay_key: Some("test-relay-key".to_owned()),
            ..Config::default()
        },
        50,
    )
    .expect("push sender");
    let app = app(store.clone(), push.clone());
    let alice = register_user(&store, "alice").await;
    let admin_role = store
        .create_role("admin", Permissions::ADMINISTRATOR, false)
        .await
        .unwrap();
    let alice_id = store
        .live_user_id_by_username("alice")
        .await
        .unwrap()
        .unwrap();
    store.assign_role(alice_id, admin_role).await.unwrap();
    let bob = register_user(&store, "bob").await;
    register_push(&app, &bob, "android", "forbidden-token").await;

    assert_eq!(push.relay_forbidden_total(), 0);
    let sent = app
        .clone()
        .oneshot(request(
            "POST",
            &format!("/channels/{channel_id}/messages"),
            Some(&alice),
            Some(json!({ "id": uuid::Uuid::now_v7().to_string(), "content": "hello" })),
        ))
        .await
        .unwrap();
    assert_eq!(sent.status(), axum::http::StatusCode::OK);

    let start = std::time::Instant::now();
    while push.relay_forbidden_total() == 0 {
        assert!(
            start.elapsed() < Duration::from_secs(5),
            "the forbidden result was never counted"
        );
        tokio::time::sleep(Duration::from_millis(15)).await;
    }
    assert_eq!(push.relay_forbidden_total(), 1);
    let text = scrape(&app, &alice).await;
    assert!(
        text.contains("slimm_push_relay_forbidden_total 1\n"),
        "{text}"
    );
}
