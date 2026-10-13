// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A poll's closing time must be ahead of now and at most 31 days out, so a
//! typo cannot make a poll closed on arrival or pin one open for years.

use axum::http::StatusCode;
use serde_json::json;
use tower::ServiceExt;
use uuid::Uuid;

mod support;
use support::overwrite_harness::{app, general_channel_id, new_store, register, request};

#[tokio::test]
async fn close_at_must_be_soon_and_in_the_future() {
    let (store, _guard) = new_store("slimm-poll-close-at").await;
    let (token, _) = register(&store, "alice").await;
    let channel = general_channel_id(&store).await;
    let app = app(store);
    let day = 24 * 60 * 60 * 1000;

    for (close_at, expected) in [
        (now_ms() - 1_000, StatusCode::BAD_REQUEST),
        (now_ms() + 32 * day, StatusCode::BAD_REQUEST),
        (now_ms() + day, StatusCode::OK),
    ] {
        let body = json!({
            "id": Uuid::now_v7().to_string(),
            "question": "lunch?",
            "options": ["yes", "no"],
            "close_at": close_at,
        });
        let response = app
            .clone()
            .oneshot(request(
                "POST",
                &format!("/channels/{channel}/messages/polls"),
                Some(&token),
                Some(body),
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), expected, "close_at {close_at}");
    }
}

fn now_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
}
