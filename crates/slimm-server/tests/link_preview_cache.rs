// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The preview cache, counted at the upstream: spellings of one URL share an
//! entry, a dead link is fetched once a minute rather than once per reader,
//! and concurrent asks share one fetch (issue 2112).

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use axum::routing::get;
use slimm_server::http::link_preview::LinkPreviews;
use tokio::net::TcpListener;
use tower::ServiceExt;

mod support;

fn app(store: slimm_server::store::Store) -> Router {
    support::app::builder(store)
        .push(slimm_server::push::PushSender::disabled())
        .link_previews(LinkPreviews::for_test())
        .router()
}

/// Serves `/page` (slowly, so concurrent asks overlap) and a dead `/dead`,
/// counting every hit.
async fn counting_upstream() -> (String, Arc<AtomicUsize>) {
    let hits = Arc::new(AtomicUsize::new(0));
    let (page_hits, dead_hits) = (hits.clone(), hits.clone());
    let router = Router::new()
        .route(
            "/page",
            get(move || {
                page_hits.fetch_add(1, Ordering::SeqCst);
                async {
                    tokio::time::sleep(Duration::from_millis(150)).await;
                    axum::response::Html("<meta property=\"og:title\" content=\"Hello\">")
                }
            }),
        )
        .route(
            "/dead",
            get(move || {
                dead_hits.fetch_add(1, Ordering::SeqCst);
                async { StatusCode::NOT_FOUND }
            }),
        );
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
    (format!("127.0.0.1:{}", addr.port()), hits)
}

async fn world(name: &str) -> (Router, String, support::TestDbGuard) {
    let (store, guard) = support::overwrite_harness::new_store(name).await;
    let (token, _) = support::overwrite_harness::register(&store, "alice").await;
    (app(store), token, guard)
}

async fn ask(app: &Router, token: &str, url: &str) -> StatusCode {
    app.clone()
        .oneshot(
            Request::builder()
                .uri(format!("/link-preview?url={url}"))
                .header("authorization", format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap()
        .status()
}

#[tokio::test]
async fn spellings_of_one_url_share_one_fetch() {
    let (app, token, _guard) = world("slimm-preview-spellings").await;
    let (host, hits) = counting_upstream().await;
    for url in [
        format!("http://{host}/page"),
        format!("HTTP://{host}/page"),
        format!("http://{host}/page%23section"),
    ] {
        assert_eq!(ask(&app, &token, &url).await, StatusCode::OK, "{url}");
    }
    assert_eq!(hits.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn a_dead_link_is_fetched_once_for_many_readers() {
    let (app, token, _guard) = world("slimm-preview-dead").await;
    let (host, hits) = counting_upstream().await;
    for _ in 0..3 {
        assert_eq!(
            ask(&app, &token, &format!("http://{host}/dead")).await,
            StatusCode::NOT_FOUND
        );
    }
    assert_eq!(hits.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn concurrent_asks_share_one_fetch() {
    let (app, token, _guard) = world("slimm-preview-concurrent").await;
    let (host, hits) = counting_upstream().await;
    let url = format!("http://{host}/page");
    let asks: Vec<_> = (0..6)
        .map(|_| {
            let (app, token, url) = (app.clone(), token.clone(), url.clone());
            tokio::spawn(async move { ask(&app, &token, &url).await })
        })
        .collect();
    for ask in asks {
        assert_eq!(ask.await.unwrap(), StatusCode::OK);
    }
    assert_eq!(hits.load(Ordering::SeqCst), 1);
}
