// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What each picture upload accepts: an avatar, the Space icon and the banner
//! are still and bounded; an emoji may move but is small.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::Value;
use tower::ServiceExt;

mod support;
use support::images::{animated_gif, png, small_jpeg, small_png};
use support::overwrite_harness::{app, new_store, register};

struct World {
    router: Router,
    admin: String,
    _guard: support::TestDbGuard,
}

async fn world() -> World {
    let (store, guard) = new_store("slimm-picture-uploads").await;
    let (admin, _) = register(&store, "root").await;
    World {
        router: app(store),
        admin,
        _guard: guard,
    }
}

impl World {
    async fn upload(&self, uri: &str, bytes: Vec<u8>) -> (StatusCode, String) {
        let request = Request::builder()
            .method("POST")
            .uri(uri)
            .header("authorization", format!("Bearer {}", self.admin))
            .header("content-type", "application/octet-stream")
            .body(Body::from(bytes))
            .unwrap();
        let response = self.router.clone().oneshot(request).await.unwrap();
        let status = response.status();
        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let error = serde_json::from_slice::<Value>(&body)
            .ok()
            .and_then(|v| v["error"].as_str().map(str::to_owned))
            .unwrap_or_default();
        (status, error)
    }
}

const STILL_ONLY: [&str; 3] = ["/me/avatar", "/space/icon", "/space/banner"];

#[tokio::test]
async fn a_still_png_or_jpeg_is_accepted_everywhere() {
    let w = world().await;
    for uri in STILL_ONLY {
        for bytes in [small_png(), small_jpeg()] {
            let (status, error) = w.upload(uri, bytes).await;
            assert_eq!(status, StatusCode::OK, "{uri}: {error}");
        }
    }
    let (status, error) = w.upload("/emoji?name=still", small_png()).await;
    assert_eq!(status, StatusCode::CREATED, "{error}");
}

#[tokio::test]
async fn an_animated_picture_is_refused_where_only_a_still_belongs() {
    let w = world().await;
    for uri in STILL_ONLY {
        let (status, error) = w.upload(uri, animated_gif()).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{uri}");
        assert!(error.ends_with("must be a still image"), "{uri}: {error}");
    }
}

#[tokio::test]
async fn an_emoji_may_animate() {
    let w = world().await;
    let (status, error) = w.upload("/emoji?name=party", animated_gif()).await;
    assert_eq!(status, StatusCode::CREATED, "{error}");
}

#[tokio::test]
async fn a_small_file_declaring_a_huge_canvas_is_refused() {
    let w = world().await;
    for uri in STILL_ONLY {
        let (status, error) = w.upload(uri, png(30_000, 30_000, b"")).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{uri}");
        assert!(error.contains("4096 pixels"), "{uri}: {error}");
    }
    let (status, error) = w.upload("/emoji?name=huge", png(1025, 16, b"")).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(error.contains("1024 pixels"), "{error}");
}

#[tokio::test]
async fn the_largest_allowed_sides_are_accepted() {
    let w = world().await;
    let (status, error) = w.upload("/space/banner", png(4096, 1024, b"")).await;
    assert_eq!(status, StatusCode::OK, "{error}");
    let (status, error) = w.upload("/emoji?name=edge", png(1024, 1024, b"")).await;
    assert_eq!(status, StatusCode::CREATED, "{error}");
}

#[tokio::test]
async fn a_bare_magic_number_is_not_a_picture() {
    let w = world().await;
    let bare = b"\x89PNG\r\n\x1a\n\x01\x02\x03\x04".to_vec();
    for uri in STILL_ONLY {
        let (status, _) = w.upload(uri, bare.clone()).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{uri}");
    }
}
