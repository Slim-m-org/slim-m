// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A signed-in caller is charged, or refused, before the server reads a request body.
//!
//! A request that declares a body and never finishes it holds an in-flight slot, so a charge
//! made after the body arrives lets a member hold slots without ever paying a token.

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
use support::app::{app, register_token};

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

fn stalled_post(uri: &str, token: &str) -> Request<Body> {
    let never = stream::pending::<Result<Bytes, std::io::Error>>();
    Request::builder()
        .method("POST")
        .uri(uri)
        .header("content-type", "application/json")
        .header("authorization", format!("Bearer {token}"))
        .body(Body::from_stream(never))
        .unwrap()
}

/// The statuses of the requests answered within two seconds; the rest were still waiting on a body.
async fn answered_without_a_body(
    app: &Router,
    uri: &str,
    token: &str,
    attempts: usize,
) -> Vec<StatusCode> {
    let mut calls = Vec::new();
    for _ in 0..attempts {
        let app = app.clone();
        let request = stalled_post(uri, token);
        calls.push(tokio::spawn(async move {
            tokio::time::timeout(Duration::from_secs(2), app.oneshot(request)).await
        }));
    }
    let mut answered = Vec::new();
    for call in calls {
        if let Ok(Ok(response)) = call.await.unwrap() {
            answered.push(response.status());
        }
    }
    answered
}

#[tokio::test]
async fn a_spent_write_bucket_answers_429_before_the_body_arrives() {
    let (store, _guard) = new_store("slimm-authed-body-charge-write").await;
    let token = register_token(&store, "owner").await;
    let app = app(store);

    let answered = answered_without_a_body(&app, "/categories", &token, 80).await;

    let rejected = answered
        .iter()
        .filter(|status| **status == StatusCode::TOO_MANY_REQUESTS)
        .count();
    assert!(
        rejected >= 20,
        "only {rejected} of 80 stalled requests were turned away; the rest held a slot"
    );
}

#[tokio::test]
async fn a_member_who_is_not_a_connector_is_refused_before_the_answer_body_arrives() {
    let (store, _guard) = new_store("slimm-authed-body-charge-connector").await;
    let token = register_token(&store, "owner").await;
    let app = app(store);
    let uri = format!("/connectors/me/runs/{}", uuid::Uuid::now_v7());

    let answered = answered_without_a_body(&app, &uri, &token, 4).await;

    assert_eq!(
        answered,
        vec![StatusCode::FORBIDDEN; 4],
        "a non-connector's stalled answer was still waiting on its body"
    );
}

#[tokio::test]
async fn a_livekit_webhook_over_64_kib_is_refused_before_it_is_verified() {
    let (store, _guard) = new_store("slimm-webhook-body-limit").await;
    let app = app(store);
    let request = Request::builder()
        .method("POST")
        .uri("/voice/webhook")
        .header("content-type", "application/webhook+json")
        .body(Body::from(vec![b'x'; 64 * 1024 + 1]))
        .unwrap();

    let response = app.oneshot(request).await.unwrap();

    assert_eq!(response.status(), StatusCode::PAYLOAD_TOO_LARGE);
}
