// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The in-flight request cap counts requests across every route, not per route.

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use axum::Router;
use axum::body::Body;
use axum::extract::State;
use axum::http::{Request, StatusCode};
use axum::routing::get;
use slimm_server::http::cap_inflight;
use tokio::sync::Semaphore;
use tower::ServiceExt;

#[derive(Clone)]
struct Gate {
    release: Arc<Semaphore>,
    entered: Arc<AtomicUsize>,
}

async fn held(State(gate): State<Gate>) -> &'static str {
    gate.entered.fetch_add(1, Ordering::SeqCst);
    let _ = gate.release.acquire().await;
    "held"
}

fn app(gate: Gate, cap: usize) -> Router {
    let routes = Router::new()
        .route("/a", get(held))
        .route("/b", get(held))
        .route("/c", get(|| async { "c" }));
    cap_inflight(routes, cap).with_state(gate)
}

async fn status(app: &Router, uri: &str) -> StatusCode {
    let request = Request::builder().uri(uri).body(Body::empty()).unwrap();
    app.clone().oneshot(request).await.unwrap().status()
}

async fn until_entered(gate: &Gate, count: usize) {
    for _ in 0..200 {
        if gate.entered.load(Ordering::SeqCst) >= count {
            return;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    panic!("{count} handlers never started");
}

#[tokio::test]
async fn requests_on_different_routes_share_one_cap() {
    let gate = Gate {
        release: Arc::new(Semaphore::new(0)),
        entered: Arc::new(AtomicUsize::new(0)),
    };
    let app = app(gate.clone(), 2);
    let first = tokio::spawn({
        let app = app.clone();
        async move { status(&app, "/a").await }
    });
    let second = tokio::spawn({
        let app = app.clone();
        async move { status(&app, "/b").await }
    });
    until_entered(&gate, 2).await;

    let third = tokio::spawn({
        let app = app.clone();
        async move { status(&app, "/c").await }
    });
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert!(
        !third.is_finished(),
        "a third route was served while two requests held the whole cap"
    );

    gate.release.add_permits(2);
    assert_eq!(first.await.unwrap(), StatusCode::OK);
    assert_eq!(second.await.unwrap(), StatusCode::OK);
    assert_eq!(
        third.await.unwrap(),
        StatusCode::OK,
        "a request over the cap queues and is served once a slot frees"
    );
}
