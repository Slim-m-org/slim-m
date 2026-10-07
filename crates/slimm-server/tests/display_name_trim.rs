// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A display name is stored trimmed, the way the other profile text fields are.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::Store;
use tower::ServiceExt;

mod support;

async fn new_store() -> (Store, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new("slimm-display-name-trim");
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
    let (store, _guard) = new_store().await;
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
    let (store, _guard) = new_store().await;
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
