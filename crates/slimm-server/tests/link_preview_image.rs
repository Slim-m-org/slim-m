// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The preview image proxy, counted at the upstream: concurrent readers of one
//! card share a fetch, a dead image is fetched once, and a fresh preview
//! fetches its image ahead of the first reader.

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode, header};
use axum::routing::get;
use slimm_server::http::link_preview::LinkPreviews;
use tokio::net::TcpListener;
use tower::ServiceExt;

mod support;

fn png() -> Vec<u8> {
    let mut out = std::io::Cursor::new(Vec::new());
    image::RgbImage::new(4, 4)
        .write_to(&mut out, image::ImageFormat::Png)
        .unwrap();
    out.into_inner()
}

struct Upstream {
    host: String,
    image_hits: Arc<AtomicUsize>,
    dead_hits: Arc<AtomicUsize>,
}

/// A page naming a slow image and a dead one, counting each image's hits.
async fn upstream() -> Upstream {
    let image_hits = Arc::new(AtomicUsize::new(0));
    let dead_hits = Arc::new(AtomicUsize::new(0));
    let (image_count, dead_count) = (image_hits.clone(), dead_hits.clone());
    let bytes = png();
    let router = Router::new()
        .route(
            "/page",
            get(|| async {
                axum::response::Html(
                    "<meta property=\"og:title\" content=\"Hello\">\
                     <meta property=\"og:image\" content=\"/card.png\">",
                )
            }),
        )
        .route(
            "/dead-page",
            get(|| async {
                axum::response::Html(
                    "<meta property=\"og:title\" content=\"Hello\">\
                     <meta property=\"og:image\" content=\"/dead.png\">",
                )
            }),
        )
        .route(
            "/card.png",
            get(move || {
                image_count.fetch_add(1, Ordering::SeqCst);
                let bytes = bytes.clone();
                async move {
                    tokio::time::sleep(Duration::from_millis(150)).await;
                    ([(header::CONTENT_TYPE, "image/png")], bytes)
                }
            }),
        )
        .route(
            "/dead.png",
            get(move || {
                dead_count.fetch_add(1, Ordering::SeqCst);
                async { StatusCode::NOT_FOUND }
            }),
        );
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
    Upstream {
        host: format!("127.0.0.1:{}", addr.port()),
        image_hits,
        dead_hits,
    }
}

async fn world(name: &str) -> (Router, String, support::TestDbGuard) {
    let (store, guard) = support::overwrite_harness::new_store(name).await;
    let (token, _) = support::overwrite_harness::register(&store, "alice").await;
    let app = support::app::builder(store)
        .push(slimm_server::push::PushSender::disabled())
        .link_previews(LinkPreviews::for_test())
        .router();
    (app, token, guard)
}

async fn get_path(app: &Router, token: &str, uri: String) -> (StatusCode, Vec<u8>) {
    let response = app
        .clone()
        .oneshot(
            Request::builder()
                .uri(uri)
                .header("authorization", format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let status = response.status();
    let body = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    (status, body.to_vec())
}

async fn image_token(app: &Router, token: &str, page: String) -> String {
    let (status, body) = get_path(app, token, format!("/link-preview?url={page}")).await;
    assert_eq!(status, StatusCode::OK);
    let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
    json["image_token"].as_str().unwrap().to_owned()
}

async fn wait_for(hits: &AtomicUsize, expected: usize) {
    for _ in 0..100 {
        if hits.load(Ordering::SeqCst) >= expected {
            return;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    panic!("the upstream was never asked");
}

#[tokio::test]
async fn concurrent_readers_of_one_card_share_the_image_fetch() {
    let (app, token, _guard) = world("slimm-image-concurrent").await;
    let up = upstream().await;
    let image = image_token(&app, &token, format!("http://{}/page", up.host)).await;
    wait_for(&up.image_hits, 1).await;
    let asks: Vec<_> = (0..6)
        .map(|_| {
            let (app, token, image) = (app.clone(), token.clone(), image.clone());
            tokio::spawn(async move {
                get_path(&app, &token, format!("/link-preview/image/{image}")).await
            })
        })
        .collect();
    for ask in asks {
        assert_eq!(ask.await.unwrap().0, StatusCode::OK);
    }
    assert_eq!(up.image_hits.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn a_fresh_preview_fetches_its_image_before_anyone_asks() {
    let (app, token, _guard) = world("slimm-image-warmed").await;
    let up = upstream().await;
    let image = image_token(&app, &token, format!("http://{}/page", up.host)).await;
    wait_for(&up.image_hits, 1).await;
    tokio::time::sleep(Duration::from_millis(300)).await;

    let started = std::time::Instant::now();
    let (status, body) = get_path(&app, &token, format!("/link-preview/image/{image}")).await;

    assert_eq!(status, StatusCode::OK);
    assert!(!body.is_empty());
    assert!(
        started.elapsed() < Duration::from_millis(100),
        "the image was already cached, so no upstream wait"
    );
    assert_eq!(up.image_hits.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn a_dead_image_is_fetched_once_for_many_readers() {
    let (app, token, _guard) = world("slimm-image-dead").await;
    let up = upstream().await;
    let image = image_token(&app, &token, format!("http://{}/dead-page", up.host)).await;
    wait_for(&up.dead_hits, 1).await;
    tokio::time::sleep(Duration::from_millis(100)).await;
    for _ in 0..3 {
        let (status, _) = get_path(&app, &token, format!("/link-preview/image/{image}")).await;
        assert_eq!(status, StatusCode::NOT_FOUND);
    }
    assert_eq!(up.dead_hits.load(Ordering::SeqCst), 1);
}
