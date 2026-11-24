// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A wake the relay could not take right now is sent again instead of dropped.

use slimm_server::push::PushSender;
use tower::ServiceExt;

use crate::push_endpoints::harness::{
    MockRelay, SHORT_DEBOUNCE_MS, WAIT_TIMEOUT, app, push_config, register_push, register_user,
    request, seeded_store, spawn_mock_relay, wait_until,
};

async fn post(app: &axum::Router, channel_id: impl std::fmt::Display, token: &str) {
    let response = app
        .clone()
        .oneshot(request(
            "POST",
            &format!("/channels/{channel_id}/messages"),
            Some(token),
            Some(serde_json::json!({ "id": uuid::Uuid::now_v7().to_string(), "content": "hi" })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), axum::http::StatusCode::OK);
}

fn bob_pushes(mock: &MockRelay) -> usize {
    mock.all_messages()
        .iter()
        .filter(|m| m["token"] == "bobs-token")
        .count()
}

macro_rules! setup {
    ($mock:ident, $app:ident, $channel:ident, $alice:ident) => {
        let (store, $channel, _guard) = seeded_store().await;
        let ($mock, relay_url) = spawn_mock_relay().await;
        let push = PushSender::with_debounce_window_ms(&push_config(&relay_url), SHORT_DEBOUNCE_MS)
            .expect("push sender");
        let $app = app(store.clone(), push);
        let ($alice, _) = register_user(&store, "alice").await;
        let (bob_token, _) = register_user(&store, "bob").await;
        register_push(&$app, &bob_token, "bobs-token").await;
    };
}

#[tokio::test]
async fn a_retry_answer_is_sent_again_and_delivered() {
    setup!(mock, app, channel_id, alice);
    mock.answer_once("bobs-token", "retry");
    post(&app, channel_id, &alice).await;
    assert!(
        wait_until(|| bob_pushes(&mock) >= 2, WAIT_TIMEOUT).await,
        "the retried device was sent to again"
    );
}

#[tokio::test]
async fn a_not_attempted_answer_is_sent_again() {
    setup!(mock, app, channel_id, alice);
    mock.answer_once("bobs-token", "not_attempted");
    post(&app, channel_id, &alice).await;
    assert!(wait_until(|| bob_pushes(&mock) >= 2, WAIT_TIMEOUT).await);
}

#[tokio::test]
async fn a_rate_limited_call_is_sent_again_after_its_retry_after() {
    setup!(mock, app, channel_id, alice);
    mock.refuse_next_call(429, Some(1));
    post(&app, channel_id, &alice).await;
    assert!(
        wait_until(|| bob_pushes(&mock) >= 1, WAIT_TIMEOUT).await,
        "the refused call was repeated"
    );
    assert_eq!(mock.attempt_count(), 2);
}

#[tokio::test]
async fn a_relay_that_keeps_saying_retry_is_given_up_on() {
    setup!(mock, app, channel_id, alice);
    for _ in 0..6 {
        mock.answer_once("bobs-token", "retry");
    }
    post(&app, channel_id, &alice).await;
    assert!(wait_until(|| mock.attempt_count() >= 3, WAIT_TIMEOUT).await);
    tokio::time::sleep(std::time::Duration::from_millis(1_500)).await;
    assert_eq!(mock.attempt_count(), 3, "one send and two resends, no more");
}

#[tokio::test]
async fn a_refusal_that_would_only_repeat_is_not_sent_again() {
    setup!(mock, app, channel_id, alice);
    mock.refuse_next_call(400, None);
    post(&app, channel_id, &alice).await;
    assert!(wait_until(|| mock.attempt_count() >= 1, WAIT_TIMEOUT).await);
    tokio::time::sleep(std::time::Duration::from_millis(1_000)).await;
    assert_eq!(mock.attempt_count(), 1);
}
