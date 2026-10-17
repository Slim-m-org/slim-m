// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A reply that pings its author pushes to them as a mention, the same way a
//! written @name does (backlog #249).

use serde_json::json;
use slimm_server::push::PushSender;
use tower::ServiceExt;

use crate::harness::{
    SHORT_DEBOUNCE_MS, WAIT_TIMEOUT, app, json_body, push_config, register_push, register_user,
    request, seeded_store, spawn_mock_relay, wait_until,
};

async fn reply_push_kind(ping: bool) -> String {
    let (store, channel_id, _guard) = seeded_store().await;
    let (mock, relay_url) = spawn_mock_relay().await;
    let push = PushSender::with_debounce_window_ms(&push_config(&relay_url), SHORT_DEBOUNCE_MS)
        .expect("push sender");
    let app = app(store.clone(), push);
    let (alice_token, _) = register_user(&store, "alice").await;
    let (bob_token, _) = register_user(&store, "bob").await;
    register_push(&app, &bob_token, "bobs-token").await;
    let send = |token: &str, body| {
        request(
            "POST",
            &format!("/channels/{channel_id}/messages"),
            Some(token),
            Some(body),
        )
    };

    let original = json_body(
        app.clone()
            .oneshot(send(
                &bob_token,
                json!({ "id": uuid::Uuid::now_v7().to_string(), "content": "lunch?" }),
            ))
            .await
            .unwrap(),
    )
    .await;
    let reply = json!({
        "id": uuid::Uuid::now_v7().to_string(),
        "content": "sure",
        "reply_to_id": original["id"],
        "mention_reply": ping,
    });
    app.clone()
        .oneshot(send(&alice_token, reply))
        .await
        .unwrap();

    assert!(
        wait_until(|| mock.call_count() >= 1, WAIT_TIMEOUT).await,
        "bob got no push"
    );
    mock.all_messages()[0]["kind"].as_str().unwrap().to_owned()
}

#[tokio::test]
async fn a_pinging_reply_pushes_as_a_mention() {
    assert_eq!(reply_push_kind(true).await, "mention");
}

#[tokio::test]
async fn a_quiet_reply_pushes_as_a_plain_message() {
    assert_eq!(reply_push_kind(false).await, "message");
}
