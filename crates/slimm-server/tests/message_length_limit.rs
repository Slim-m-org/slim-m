// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Over the character limit is a 400 naming how far over, not a bare
//! rejection: a client silently retrying the same doomed content needs the
//! number to know why every attempt fails identically. Split out of
//! `message_endpoints.rs`, already at its own allowlisted line ceiling.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::permissions::Permissions;
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::Store;
use tower::ServiceExt;
use uuid::Uuid;

mod support;

/// Builds a router sharing `store`, so roles and channels created directly on
/// the store are visible to the handlers.
fn app(store: Store) -> Router {
    let auth = Auth::new(2).expect("auth service");
    http::router(AppState {
        store,
        auth,
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
/// `message_endpoints.rs`'s own copy of this helper for why it is not
/// `/auth/register`.
async fn register(store: &Store, username: &str) -> (String, String) {
    let account = store
        .create_account(username, username, "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    let tokens = store.open_session(account.id, "cli").await.unwrap();
    (tokens.access_token, account.id.to_string())
}

#[tokio::test]
async fn over_the_character_limit_names_the_overage() {
    let (store, _guard) = support::new_store("slimm-msg-limit-test").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone());
    let (token, _user) = register(&store, "alice").await;

    let uri = format!("/channels/{}/messages", channel.id);
    let over_by = 37;
    let content = "a".repeat(4000 + over_by);
    let response = app
        .clone()
        .oneshot(request(
            "POST",
            &uri,
            Some(&token),
            Some(json!({ "id": Uuid::now_v7().to_string(), "content": content })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    let body = json_body(response).await;
    let error = body["error"].as_str().unwrap();
    assert!(
        error.contains("37"),
        "error did not name the overage: {error}"
    );
    assert!(
        error.contains("4000"),
        "error did not name the limit: {error}"
    );
}

/// Content right at the limit, not one character past it, is accepted -
/// pinned so the boundary is never off by one in either direction.
#[tokio::test]
async fn content_exactly_at_the_limit_is_accepted() {
    let (store, _guard) = support::new_store("slimm-msg-limit-test").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone());
    let (token, _user) = register(&store, "alice").await;

    let uri = format!("/channels/{}/messages", channel.id);
    let content = "a".repeat(4000);
    let response = app
        .clone()
        .oneshot(request(
            "POST",
            &uri,
            Some(&token),
            Some(json!({ "id": Uuid::now_v7().to_string(), "content": content })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
}
