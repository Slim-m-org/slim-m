// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A failed avatar write or read answers 500, and a failed write never marks
//! the avatar as set (issue 2100).

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use slimm_server::auth::Auth;
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::media::Media;
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::Store;
use tower::ServiceExt;

mod support;

fn app(store: Store, media: Media) -> Router {
    http::router(AppState {
        store,
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
    })
}

fn request(method: &str, uri: &str, token: &str, body: Vec<u8>) -> Request<Body> {
    Request::builder()
        .method(method)
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .body(Body::from(body))
        .unwrap()
}

async fn world(
    name: &str,
) -> (
    Store,
    String,
    String,
    std::path::PathBuf,
    Vec<support::TestDirGuard>,
    support::TestDbGuard,
) {
    let (store, db_guard) = support::overwrite_harness::new_store(name).await;
    let (token, user_id) = support::overwrite_harness::register(&store, "alice").await;
    let (root, dir_guard) = support::TestDirGuard::new(name);
    (store, token, user_id, root, vec![dir_guard], db_guard)
}

#[tokio::test]
async fn a_failed_write_answers_500_and_leaves_no_avatar_set() {
    let (store, token, user_id, root, _dirs, _db) = world("slimm-avatar-write-fail").await;
    let media = Media::new(&root, 1 << 20).unwrap();
    std::fs::remove_dir_all(root.join("avatars")).unwrap();
    std::fs::write(root.join("avatars"), b"not a directory").unwrap();
    let app = app(store.clone(), media);

    let response = app
        .oneshot(request(
            "POST",
            "/me/avatar",
            &token,
            support::images::small_png(),
        ))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::INTERNAL_SERVER_ERROR);
    let user = store
        .user_profile(slimm_server::ids::UserId(user_id.parse().unwrap()))
        .await
        .unwrap()
        .unwrap();
    assert!(
        user.avatar_updated_at.is_none(),
        "an avatar with no file was marked set"
    );
}

#[tokio::test]
async fn a_failed_read_answers_500() {
    let (store, token, user_id, root, _dirs, _db) = world("slimm-avatar-read-fail").await;
    let media = Media::new(&root, 1 << 20).unwrap();
    let app = app(store, media);
    let uploaded = app
        .clone()
        .oneshot(request(
            "POST",
            "/me/avatar",
            &token,
            support::images::small_png(),
        ))
        .await
        .unwrap();
    assert_eq!(uploaded.status(), StatusCode::OK);
    std::fs::remove_file(root.join("avatars").join(&user_id)).unwrap();

    let fetched = app
        .oneshot(request(
            "GET",
            &format!("/users/{user_id}/avatar"),
            &token,
            Vec::new(),
        ))
        .await
        .unwrap();
    assert_eq!(fetched.status(), StatusCode::INTERNAL_SERVER_ERROR);
}
