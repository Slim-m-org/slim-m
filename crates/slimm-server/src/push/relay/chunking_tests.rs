// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `relay::send` against a stub that enforces the relay's per-request message cap.

use std::sync::{Arc, Mutex};

use axum::extract::State;
use axum::http::StatusCode;
use axum::routing::post;
use axum::{Json, Router};
use serde_json::{Value, json};
use tokio::net::TcpListener;

use super::*;
use crate::ids::{DeviceId, UserId};
use crate::push::sealing::TokenSlot;

const RELAY_MAX_MESSAGES: usize = 500;

#[derive(Clone)]
struct Stub {
    batch_sizes: Arc<Mutex<Vec<usize>>>,
    fail_token: Option<&'static str>,
}

async fn handle(State(stub): State<Stub>, Json(body): Json<Value>) -> (StatusCode, Json<Value>) {
    let messages = body["messages"].as_array().unwrap();
    stub.batch_sizes.lock().unwrap().push(messages.len());
    let rejected = messages.len() > RELAY_MAX_MESSAGES
        || messages
            .iter()
            .any(|m| Some(m["token"].as_str().unwrap()) == stub.fail_token);
    if rejected {
        return (StatusCode::BAD_REQUEST, Json(json!({"error": "rejected"})));
    }
    let results: Vec<Value> = messages
        .iter()
        .map(|m| json!({"token": m["token"], "status": "delivered"}))
        .collect();
    (StatusCode::OK, Json(json!({ "results": results })))
}

async fn spawn_stub(fail_token: Option<&'static str>) -> (String, Stub) {
    let stub = Stub {
        batch_sizes: Arc::default(),
        fail_token,
    };
    let app = Router::new()
        .route("/v1/send", post(handle))
        .with_state(stub.clone());
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}/v1/send", listener.local_addr().unwrap());
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    (url, stub)
}

fn sealed(count: usize) -> Vec<SealedMessage> {
    (0..count)
        .map(|i| SealedMessage {
            user_id: UserId::generate(),
            device_id: DeviceId::generate(),
            platform: "android".to_owned(),
            token: format!("token-{i}"),
            slot: TokenSlot::Push,
            kind: "message",
            payload: "sealed".to_owned(),
        })
        .collect()
}

#[tokio::test]
async fn a_batch_over_the_relay_cap_is_split_and_every_device_is_answered() {
    let (url, stub) = spawn_stub(None).await;
    let messages = sealed(RELAY_MAX_MESSAGES + 1);
    let results = send(&reqwest::Client::new(), &url, "key", &messages)
        .await
        .expect("a 501-device batch must not be refused as a whole");
    assert_eq!(results.len(), messages.len());
    assert!(
        stub.batch_sizes
            .lock()
            .unwrap()
            .iter()
            .all(|n| *n <= MAX_BATCH)
    );
}

#[tokio::test]
async fn a_rejected_chunk_only_loses_its_own_devices() {
    let (url, _stub) = spawn_stub(Some("token-0")).await;
    let messages = sealed(MAX_BATCH * 2);
    let results = send(&reqwest::Client::new(), &url, "key", &messages)
        .await
        .expect("one good chunk is enough for a partial answer");
    assert_eq!(results.len(), MAX_BATCH);
    assert!(results.iter().all(|r| r.token != "token-0"));
}

#[tokio::test]
async fn every_chunk_failing_is_an_error() {
    let (url, _stub) = spawn_stub(Some("token-0")).await;
    let messages = sealed(MAX_BATCH);
    assert!(
        send(&reqwest::Client::new(), &url, "key", &messages)
            .await
            .is_err()
    );
}
