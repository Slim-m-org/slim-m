// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! An unauthenticated body route charges its rate limit before reading the body.
//!
//! A request that declares a body and never finishes it holds an in-flight slot, so
//! the charge has to come first or a client can hold slots without ever paying.

use std::time::Duration;

use axum::Router;
use axum::body::{Body, Bytes};
use axum::http::{Request, StatusCode};
use futures_util::stream;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::store::Store;
use tower::ServiceExt;

use crate::support;
use support::app::app;

async fn new_store(name: &str) -> (Store, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new(name);
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool), guard)
}

fn stalled_post(uri: &str, content_type: &str) -> Request<Body> {
    let never = stream::pending::<Result<Bytes, std::io::Error>>();
    Request::builder()
        .method("POST")
        .uri(uri)
        .header("content-type", content_type)
        .body(Body::from_stream(never))
        .unwrap()
}

/// How many of `attempts` concurrent requests with a body that never arrives were answered 429.
async fn rejected_without_a_body(
    app: &Router,
    uri: &str,
    content_type: &str,
    attempts: usize,
) -> usize {
    let mut calls = Vec::new();
    for _ in 0..attempts {
        let app = app.clone();
        let request = stalled_post(uri, content_type);
        calls.push(tokio::spawn(async move {
            tokio::time::timeout(Duration::from_secs(2), app.oneshot(request)).await
        }));
    }
    let mut rejected = 0;
    for call in calls {
        if let Ok(Ok(response)) = call.await.unwrap() {
            assert_eq!(response.status(), StatusCode::TOO_MANY_REQUESTS);
            rejected += 1;
        }
    }
    rejected
}

#[tokio::test]
async fn a_spent_webhook_bucket_answers_429_before_the_body_arrives() {
    let (store, _guard) = new_store("slimm-body-charge-webhook").await;
    let app = app(store);
    let uri = format!("/webhooks/{}/{}", uuid::Uuid::now_v7(), "not-a-token");

    let rejected = rejected_without_a_body(&app, &uri, "application/json", 60).await;

    assert!(
        rejected >= 20,
        "only {rejected} of 60 stalled requests were turned away; the rest held a slot"
    );
}

#[tokio::test]
async fn a_spent_livekit_webhook_bucket_answers_429_before_the_body_arrives() {
    let (store, _guard) = new_store("slimm-body-charge-livekit").await;
    let app = app(store);

    let rejected =
        rejected_without_a_body(&app, "/voice/webhook", "application/webhook+json", 200).await;

    assert!(
        rejected >= 20,
        "only {rejected} of 200 stalled requests were turned away; the rest held a slot"
    );
}
