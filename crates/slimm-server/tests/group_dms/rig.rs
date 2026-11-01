// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The harness and request helpers every group DM test shares.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::hub::Hub;
use slimm_server::store::Store;
use slimm_server::voice::VoiceService;
use tower::ServiceExt;
use uuid::Uuid;

use crate::support;
use crate::support::app::{register_token_id as register, request};

pub(crate) struct Harness {
    pub(crate) app: Router,
    pub(crate) store: Store,
    pub(crate) hub: Hub,
    pub(crate) _guard: support::TestDbGuard,
}

pub(crate) async fn harness() -> Harness {
    let (path, guard) = support::TestDbGuard::new("slimm-group-dms-test");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let store = Store::new(db::connect(&config).await.expect("connect + migrate"));
    let hub = Hub::new();
    let voice = VoiceService::for_test(
        "wss://livekit.example.com",
        "APItestkey",
        "a-test-secret-of-at-least-32-characters",
    );
    let app = support::app::builder(store.clone())
        .hub(hub.clone())
        .voice(voice)
        .router();
    Harness {
        app,
        store,
        hub,
        _guard: guard,
    }
}

pub(crate) struct Person {
    pub(crate) token: String,
    pub(crate) id: String,
}

pub(crate) async fn person(h: &Harness, name: &str) -> Person {
    let (token, id) = register(&h.store, name).await;
    Person { token, id }
}

pub(crate) async fn call(
    h: &Harness,
    method: &str,
    uri: &str,
    who: &Person,
    body: Option<Value>,
) -> (StatusCode, Value) {
    let response = h
        .app
        .clone()
        .oneshot(request(method, uri, Some(&who.token), body))
        .await
        .unwrap();
    let status = response.status();
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    (
        status,
        serde_json::from_slice(&bytes).unwrap_or(Value::Null),
    )
}

pub(crate) async fn create(h: &Harness, by: &Person, others: &[&Person]) -> (StatusCode, Value) {
    let ids: Vec<&str> = others.iter().map(|p| p.id.as_str()).collect();
    call(
        h,
        "POST",
        "/dms/groups",
        by,
        Some(json!({ "id": Uuid::now_v7().to_string(), "user_ids": ids })),
    )
    .await
}

pub(crate) async fn group_of(h: &Harness, by: &Person, others: &[&Person]) -> String {
    let (status, body) = create(h, by, others).await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
    body["channel_id"].as_str().unwrap().to_owned()
}

pub(crate) async fn send(h: &Harness, channel: &str, who: &Person, text: &str) -> StatusCode {
    call(
        h,
        "POST",
        &format!("/channels/{channel}/messages"),
        who,
        Some(json!({ "id": Uuid::now_v7().to_string(), "content": text })),
    )
    .await
    .0
}

pub(crate) async fn read(h: &Harness, channel: &str, who: &Person) -> StatusCode {
    call(
        h,
        "GET",
        &format!("/channels/{channel}/messages"),
        who,
        None,
    )
    .await
    .0
}

pub(crate) async fn block(h: &Harness, blocker: &Person, target: &Person) {
    let (status, _) = call(h, "POST", &format!("/blocks/{}", target.id), blocker, None).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
}

pub(crate) async fn list(h: &Harness, who: &Person) -> Vec<Value> {
    call(h, "GET", "/dms", who, None)
        .await
        .1
        .as_array()
        .unwrap()
        .clone()
}

pub(crate) fn member_ids(group: &Value) -> Vec<String> {
    group["members"]
        .as_array()
        .unwrap()
        .iter()
        .map(|m| m["id"].as_str().unwrap().to_owned())
        .collect()
}

pub(crate) async fn ring(h: &Harness, channel: &str, who: &Person) -> StatusCode {
    call(
        h,
        "POST",
        &format!("/channels/{channel}/voice/ring"),
        who,
        None,
    )
    .await
    .0
}

pub(crate) async fn incoming(h: &Harness, who: &Person) -> Vec<Value> {
    call(h, "GET", "/voice/rings/incoming", who, None).await.1["rings"]
        .as_array()
        .unwrap()
        .clone()
}

pub(crate) async fn decline(h: &Harness, channel: &str, who: &Person) {
    let (status, _) = call(
        h,
        "POST",
        &format!("/channels/{channel}/voice/ring/decline"),
        who,
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
}
