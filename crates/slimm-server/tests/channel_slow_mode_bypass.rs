// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Slow mode cannot be skipped by deleting the last message or by sending in
//! parallel; the window is measured and checked inside the send transaction.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::permissions::Permissions;
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::Store;
use tower::ServiceExt;
use uuid::Uuid;

mod support;

async fn new_store() -> (Store, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new("slimm-slow-mode-bypass");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool), guard)
}

fn app(store: Store) -> Router {
    http::router(AppState {
        store,
        auth: Auth::new(2).unwrap(),
        hub: Hub::new(),
        limiter: RateLimiter::new(),
        push: PushSender::disabled(),
        voice: slimm_server::voice::VoiceService::disabled(),
        media: slimm_server::media::Media::for_tests(),
        gifs: slimm_server::http::gifs::GifSearch::disabled(),
        link_previews: slimm_server::http::link_preview::LinkPreviews::disabled(),
        dock: slimm_server::http::dock::Dock::disabled(),
        code_runner: slimm_server::code_runner::CodeRunner::disabled(),
    })
}

fn request(method: &str, uri: &str, token: Option<&str>, body: Option<Value>) -> Request<Body> {
    let mut builder = Request::builder().method(method).uri(uri);
    if let Some(token) = token {
        builder = builder.header("authorization", format!("Bearer {token}"));
    }
    match body {
        Some(value) => builder
            .header("content-type", "application/json")
            .body(Body::from(value.to_string()))
            .unwrap(),
        None => builder.body(Body::empty()).unwrap(),
    }
}

async fn json_body(response: axum::response::Response) -> Value {
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    serde_json::from_slice(&bytes).unwrap()
}

/// A member with a session, built straight through the store; see
/// `channel_topic.rs`'s own copy of this helper for why it bypasses
/// `/auth/register`.
async fn register(store: &Store, username: &str) -> String {
    let account = store
        .create_account(username, username, "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    store
        .open_session(account.id, "cli")
        .await
        .unwrap()
        .access_token
}

fn send(uri: &str, token: &str, content: &str) -> Request<Body> {
    request(
        "POST",
        uri,
        Some(token),
        Some(json!({ "id": Uuid::now_v7().to_string(), "content": content })),
    )
}

async fn setup() -> (
    Store,
    support::TestDbGuard,
    Router,
    String,
    slimm_server::store::Channel,
) {
    let (store, guard) = new_store().await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    store
        .update_channel_slow_mode(channel.id, 60)
        .await
        .unwrap();
    let app = app(store.clone());
    let _admin = register(&store, "admin").await;
    let token = register(&store, "bob").await;
    (store, guard, app, token, channel)
}

#[tokio::test]
async fn deleting_the_last_message_does_not_reset_slow_mode() {
    let (_store, _guard, app, token, channel) = setup().await;
    let uri = format!("/channels/{}/messages", channel.id);
    let first = app
        .clone()
        .oneshot(send(&uri, &token, "one"))
        .await
        .unwrap();
    assert_eq!(first.status(), StatusCode::OK);
    let m1 = json_body(first).await;
    let del = app
        .clone()
        .oneshot(request(
            "DELETE",
            &format!("{uri}/{}", m1["id"].as_str().unwrap()),
            Some(&token),
            None,
        ))
        .await
        .unwrap();
    assert!(del.status().is_success(), "delete: {}", del.status());
    let second = app
        .clone()
        .oneshot(send(&uri, &token, "two"))
        .await
        .unwrap();
    assert_eq!(
        second.status(),
        StatusCode::TOO_MANY_REQUESTS,
        "send right after deleting own last message"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn parallel_sends_pass_slow_mode_only_once() {
    let (_store, _guard, app, token, channel) = setup().await;
    let uri = format!("/channels/{}/messages", channel.id);
    let mut handles = Vec::new();
    for i in 0..8 {
        let app = app.clone();
        let uri = uri.clone();
        let token = token.clone();
        handles.push(tokio::spawn(async move {
            app.oneshot(send(&uri, &token, &format!("p{i}")))
                .await
                .unwrap()
                .status()
        }));
    }
    let mut ok = 0;
    for h in handles {
        if h.await.unwrap() == StatusCode::OK {
            ok += 1;
        }
    }
    assert_eq!(
        ok, 1,
        "exactly one of 8 parallel sends may pass a 60s slow mode"
    );
}
