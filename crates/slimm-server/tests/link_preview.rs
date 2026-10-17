// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The click-to-play video flag on a link preview: a page whose `og:video`
//! names a YouTube embed is flagged playable with the video's id, and an
//! ordinary page is not. The fake upstream here never is youtube.com - only
//! the id-parsing in `http::link_preview::video` needs to run for this, so
//! the og:video URL string is enough; no real network reaches Google.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use axum::routing::get;
use serde_json::Value;
use slimm_server::auth::Auth;
use slimm_server::http::link_preview::LinkPreviews;
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::media::Media;
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::Store;
use tokio::net::TcpListener;
use tower::ServiceExt;

mod support;

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
        link_previews: LinkPreviews::for_test(),
        dock: slimm_server::http::dock::Dock::disabled(),
        code_runner: slimm_server::code_runner::CodeRunner::disabled(),
    })
}

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

fn req_get(uri: &str, token: &str) -> Request<Body> {
    Request::builder()
        .method("GET")
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap()
}

/// A minimal fake upstream serving one page at `/page`, with [body] as its
/// full HTML.
async fn fake_upstream(body: &'static str) -> String {
    let router = Router::new().route(
        "/page",
        get(move || async move { axum::response::Html(body) }),
    );
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
    format!("http://{addr}")
}

async fn preview_json(store: Store, token: &str, upstream: &str) -> Value {
    let response = app(store)
        .oneshot(req_get(
            &format!("/link-preview?url={upstream}/page"),
            token,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    serde_json::from_slice(&bytes).unwrap()
}

#[tokio::test]
async fn a_page_whose_og_video_is_a_youtube_embed_is_flagged_playable() {
    let (store, _guard) = support::new_store("slimm-link-preview-video-test").await;
    let token = register(&store, "video_watcher").await;
    let upstream = fake_upstream(
        "<meta property=\"og:title\" content=\"A talk\">\
         <meta property=\"og:video\" content=\"https://www.youtube.com/embed/dQw4w9WgXcQ\">",
    )
    .await;

    let json = preview_json(store, &token, &upstream).await;
    assert_eq!(json["video_provider"], "youtube");
    assert_eq!(json["video_id"], "dQw4w9WgXcQ");
}

#[tokio::test]
async fn an_ordinary_page_is_not_flagged_playable() {
    let (store, _guard) = support::new_store("slimm-link-preview-video-test").await;
    let token = register(&store, "reader").await;
    let upstream = fake_upstream("<meta property=\"og:title\" content=\"Just a blog post\">").await;

    let json = preview_json(store, &token, &upstream).await;
    assert_eq!(json["video_provider"], Value::Null);
    assert_eq!(json["video_id"], Value::Null);
}

#[tokio::test]
async fn an_ordinary_page_carries_no_author_and_makes_no_oembed_request() {
    // Only a URL video::detect recognizes as YouTube ever takes the oembed branch that could populate these.
    let (store, _guard) = support::new_store("slimm-link-preview-video-test").await;
    let token = register(&store, "reader").await;
    let upstream = fake_upstream("<meta property=\"og:title\" content=\"Just a blog post\">").await;

    let json = preview_json(store, &token, &upstream).await;
    assert_eq!(json["author_name"], Value::Null);
    assert_eq!(json["author_url"], Value::Null);
}

#[tokio::test]
async fn a_youtube_watch_url_pasted_directly_is_flagged_playable() {
    let (store, _guard) = support::new_store("slimm-link-preview-video-test").await;
    let token = register(&store, "paster").await;
    // A real watch URL in the page's own og:video, exercising the URL-path branch, not the og:video fallback.
    let upstream = fake_upstream(
        "<meta property=\"og:title\" content=\"Rick Astley - Never Gonna Give You Up\">\
         <meta property=\"og:video\" content=\"https://www.youtube.com/watch?v=dQw4w9WgXcQ\">",
    )
    .await;

    let json = preview_json(store, &token, &upstream).await;
    assert_eq!(json["video_provider"], "youtube");
    assert_eq!(json["video_id"], "dQw4w9WgXcQ");
}
