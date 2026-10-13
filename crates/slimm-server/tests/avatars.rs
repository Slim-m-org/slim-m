// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! HTTP integration tests for avatars: upload, fetch, and delete. Kept
//! separate from `attachments.rs` because avatars are deliberately not
//! attachments (see migration 0013) - one mutable image per user, gated by
//! authentication only, never by a channel permission.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use slimm_server::auth::Auth;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::http::{self, AppState};
use slimm_server::hub::{Event, Hub};
use slimm_server::media::Media;
use slimm_server::permissions::Permissions;
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::Store;
use tower::ServiceExt;

mod support;

async fn new_store() -> (Store, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new("slimm-avatars-test");
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
        media: Media::for_tests(),
        gifs: slimm_server::http::gifs::GifSearch::disabled(),
        link_previews: slimm_server::http::link_preview::LinkPreviews::disabled(),
        dock: slimm_server::http::dock::Dock::disabled(),
        code_runner: slimm_server::code_runner::CodeRunner::disabled(),
    })
}

fn request_bytes(method: &str, uri: &str, token: &str, body: Vec<u8>) -> Request<Body> {
    Request::builder()
        .method(method)
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .body(Body::from(body))
        .unwrap()
}

const PASSWORD: &str = "correct-horse-battery";

fn request_plain(method: &str, uri: &str, token: &str) -> Request<Body> {
    Request::builder()
        .method(method)
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap()
}

async fn json_body(response: axum::response::Response) -> serde_json::Value {
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    serde_json::from_slice(&bytes).unwrap()
}

async fn register(store: &Store, username: &str) -> String {
    let hash = Auth::new(2)
        .unwrap()
        .hash_password(PASSWORD.to_owned())
        .await
        .unwrap();
    let account = store
        .create_account(username, username, &hash)
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    store
        .open_session(account.id, "cli")
        .await
        .unwrap()
        .access_token
}

fn png(padding: usize) -> Vec<u8> {
    let mut bytes = support::images::small_png();
    bytes.extend(std::iter::repeat_n(0u8, padding));
    bytes
}

/// Setting or clearing an avatar is announced, the same way a rename is.
///
/// A client caches avatar bytes under `(user_id, avatar_updated_at)`, so a
/// picture that changes with no event leaves every other client holding the
/// old key - and therefore the old face - until it restarts and refetches
/// profiles from scratch. That is exactly what happened: `update_me`
/// published `ProfileChanged` and the two avatar routes published nothing.
#[tokio::test]
async fn changing_an_avatar_announces_the_profile_change() {
    let (store, _guard) = new_store().await;
    store
        .create_role("everyone", Permissions::VIEW_CHANNEL, true)
        .await
        .unwrap();
    let (root, _media_guard) = support::TestDirGuard::new("slimm-avatars-event");
    let media = Media::new(&root, 10 * 1024 * 1024).expect("create temp media directories");
    let hub = Hub::new();
    let mut events = hub.subscribe();
    let app = http::router(AppState {
        store: store.clone(),
        auth: Auth::new(2).unwrap(),
        hub: hub.clone(),
        limiter: RateLimiter::new(),
        push: PushSender::disabled(),
        voice: slimm_server::voice::VoiceService::disabled(),
        media,
        gifs: slimm_server::http::gifs::GifSearch::disabled(),
        link_previews: slimm_server::http::link_preview::LinkPreviews::disabled(),
        dock: slimm_server::http::dock::Dock::disabled(),
        code_runner: slimm_server::code_runner::CodeRunner::disabled(),
    });
    let token = register(&store, "alice").await;
    let me = json_body(
        app.clone()
            .oneshot(request_plain("GET", "/me", &token))
            .await
            .unwrap(),
    )
    .await;
    let user_id = me["id"].as_str().unwrap().to_owned();

    let uploaded = app
        .clone()
        .oneshot(request_bytes("POST", "/me/avatar", &token, png(8)))
        .await
        .unwrap();
    assert_eq!(uploaded.status(), StatusCode::OK);
    assert!(
        matches!(events.try_recv(), Ok(Event::ProfileChanged(id)) if id.to_string() == user_id),
        "an upload must announce the profile change"
    );

    let deleted = app
        .oneshot(request_plain("DELETE", "/me/avatar", &token))
        .await
        .unwrap();
    assert_eq!(deleted.status(), StatusCode::NO_CONTENT);
    assert!(
        matches!(events.try_recv(), Ok(Event::ProfileChanged(id)) if id.to_string() == user_id),
        "clearing a picture is a profile change too"
    );
}

#[tokio::test]
async fn uploading_an_avatar_is_reflected_on_the_profile_and_is_fetchable() {
    let (store, _guard) = new_store().await;
    store
        .create_role("everyone", Permissions::VIEW_CHANNEL, true)
        .await
        .unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;

    let before = json_body(
        app.clone()
            .oneshot(request_plain("GET", "/me", &token))
            .await
            .unwrap(),
    )
    .await;
    assert!(before["avatar_updated_at"].is_null());

    let uploaded = app
        .clone()
        .oneshot(request_bytes("POST", "/me/avatar", &token, png(8)))
        .await
        .unwrap();
    assert_eq!(uploaded.status(), StatusCode::OK);
    let uploaded = json_body(uploaded).await;
    assert!(uploaded["avatar_updated_at"].is_i64());
    let user_id = uploaded["id"].as_str().unwrap();

    let fetched = app
        .clone()
        .oneshot(request_plain(
            "GET",
            &format!("/users/{user_id}/avatar"),
            &token,
        ))
        .await
        .unwrap();
    assert_eq!(fetched.status(), StatusCode::OK);
    assert_eq!(fetched.headers().get("content-type").unwrap(), "image/png");
    assert_eq!(
        fetched.headers().get("x-content-type-options").unwrap(),
        "nosniff"
    );
}

#[tokio::test]
async fn a_user_with_no_avatar_answers_not_found() {
    let (store, _guard) = new_store().await;
    store
        .create_role("everyone", Permissions::VIEW_CHANNEL, true)
        .await
        .unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;

    let me = json_body(
        app.clone()
            .oneshot(request_plain("GET", "/me", &token))
            .await
            .unwrap(),
    )
    .await;
    let user_id = me["id"].as_str().unwrap();

    let response = app
        .clone()
        .oneshot(request_plain(
            "GET",
            &format!("/users/{user_id}/avatar"),
            &token,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn deleting_an_avatar_clears_it() {
    let (store, _guard) = new_store().await;
    store
        .create_role("everyone", Permissions::VIEW_CHANNEL, true)
        .await
        .unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;

    app.clone()
        .oneshot(request_bytes("POST", "/me/avatar", &token, png(8)))
        .await
        .unwrap();

    let deleted = app
        .clone()
        .oneshot(request_plain("DELETE", "/me/avatar", &token))
        .await
        .unwrap();
    assert_eq!(deleted.status(), StatusCode::NO_CONTENT);

    let me = json_body(
        app.clone()
            .oneshot(request_plain("GET", "/me", &token))
            .await
            .unwrap(),
    )
    .await;
    assert!(me["avatar_updated_at"].is_null());
}

/// `DELETE /account` used to purge everything about a user except the avatar
/// file itself: only the self-service `DELETE /me/avatar` path removed it, so
/// a deleted account left its picture behind on disk forever.
#[tokio::test]
async fn deleting_an_account_removes_its_avatar_file() {
    let (store, _guard) = new_store().await;
    store
        .create_role("everyone", Permissions::VIEW_CHANNEL, true)
        .await
        .unwrap();
    let (root, _media_guard) = support::TestDirGuard::new("slimm-avatars-account-delete");
    let media = Media::new(&root, 10 * 1024 * 1024).expect("create temp media directories");
    let app = http::router(AppState {
        store: store.clone(),
        auth: Auth::new(2).unwrap(),
        hub: Hub::new(),
        limiter: RateLimiter::new(),
        push: PushSender::disabled(),
        voice: slimm_server::voice::VoiceService::disabled(),
        media,
        gifs: slimm_server::http::gifs::GifSearch::disabled(),
        link_previews: slimm_server::http::link_preview::LinkPreviews::disabled(),
        dock: slimm_server::http::dock::Dock::disabled(),
        code_runner: slimm_server::code_runner::CodeRunner::disabled(),
    });
    let token = register(&store, "alice").await;

    let me = json_body(
        app.clone()
            .oneshot(request_plain("GET", "/me", &token))
            .await
            .unwrap(),
    )
    .await;
    let user_id = me["id"].as_str().unwrap().to_owned();

    app.clone()
        .oneshot(request_bytes("POST", "/me/avatar", &token, png(8)))
        .await
        .unwrap();
    let avatar_file = root.join("avatars").join(&user_id);
    assert!(avatar_file.exists(), "the upload landed on disk");

    let deleted = app
        .clone()
        .oneshot(
            Request::builder()
                .method("DELETE")
                .uri("/account")
                .header("authorization", format!("Bearer {token}"))
                .header("content-type", "application/json")
                .body(Body::from(format!(r#"{{"password":"{PASSWORD}"}}"#)))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(deleted.status(), StatusCode::NO_CONTENT);

    assert!(
        !avatar_file.exists(),
        "the avatar file must not outlive the account"
    );
}

#[tokio::test]
async fn a_non_image_avatar_is_refused() {
    let (store, _guard) = new_store().await;
    store
        .create_role("everyone", Permissions::VIEW_CHANNEL, true)
        .await
        .unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;

    // A PDF passes the general attachment allowlist but must not pass as an
    // avatar: an avatar is always a picture.
    let pdf = b"%PDF-1.7 not really a pdf".to_vec();
    let response = app
        .clone()
        .oneshot(request_bytes("POST", "/me/avatar", &token, pdf))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}
