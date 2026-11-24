// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A snooze counts from the server's clock when the client sends a duration, so a device clock that is wrong cannot move it.

use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::http;
use tower::ServiceExt;

use crate::support;
use support::app::request_json as request;

fn now_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
}

async fn snooze(state: &http::AppState, token: &str, body: Value) -> (StatusCode, Value) {
    let response = http::router(state.clone())
        .oneshot(request(
            "PUT",
            "/notifications/schedule/snooze",
            token,
            body,
        ))
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

#[tokio::test]
async fn a_duration_is_counted_from_the_server_clock() {
    let (store, _guard) = support::new_store("slimm-snooze-duration").await;
    let state = support::app::state(store.clone());
    let user = store.create_user("alice", "alice").await.unwrap();
    let session = store.open_session(user.id, "phone").await.unwrap();

    let before = now_ms();
    let (status, body) = snooze(
        &state,
        &session.access_token,
        json!({ "duration_seconds": 1800 }),
    )
    .await;
    let after = now_ms();

    assert_eq!(status, StatusCode::OK, "{body}");
    let until = body["snooze_until"].as_i64().unwrap();
    assert!(
        (before + 1_800_000..=after + 1_800_000).contains(&until),
        "{until}"
    );
}

#[tokio::test]
async fn a_snooze_needs_exactly_one_way_to_say_when() {
    let (store, _guard) = support::new_store("slimm-snooze-one-way").await;
    let state = support::app::state(store.clone());
    let user = store.create_user("alice", "alice").await.unwrap();
    let session = store.open_session(user.id, "phone").await.unwrap();
    let token = &session.access_token;

    let both = json!({ "duration_seconds": 60, "until_ms": now_ms() + 60_000 });
    for body in [
        json!({}),
        both,
        json!({ "duration_seconds": 0 }),
        json!({ "duration_seconds": -5 }),
    ] {
        let (status, _) = snooze(&state, token, body.clone()).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{body}");
    }
    let (status, _) = snooze(&state, token, json!({ "duration_seconds": 8 * 24 * 3600 })).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    let (status, body) = snooze(&state, token, json!({ "until_ms": now_ms() + 60_000 })).await;
    assert_eq!(
        status,
        StatusCode::OK,
        "the older absolute form still works: {body}"
    );
}
