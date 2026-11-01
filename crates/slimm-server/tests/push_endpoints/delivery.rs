// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The tests themselves: registration over HTTP, triggering from the message
//! send path, lifecycle gating, debounce, and a dead token clearing the
//! registration. See `harness.rs` for the store, router, and mock relay they
//! all share.

use std::time::Duration;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use serde_json::{Value, json};
use slimm_server::push::PushSender;
use tower::ServiceExt;

use crate::harness::{
    SHORT_DEBOUNCE_MS, WAIT_TIMEOUT, app, json_body, push_config, register_push, register_user,
    request, seeded_store, spawn_mock_relay, wait_until, wait_until_async,
};

/// A mock relay is running, but the sender under test is disabled and was never
/// told its address: if `PushSender::disabled()` were not a genuine no-op, that
/// mock is what would catch a stray call.
#[tokio::test]
async fn a_disabled_sender_never_reaches_a_relay() {
    let (store, channel_id, _guard) = seeded_store().await;
    let (mock, _addr) = spawn_mock_relay().await;

    let app = app(store.clone(), PushSender::disabled());
    let (alice_token, _alice_id) = register_user(&store, "alice").await;
    let _bob_secret = {
        let (bob_token, _bob_id) = register_user(&store, "bob").await;
        register_push(&app, &bob_token, "bobs-token").await
    };

    let sent = app
        .clone()
        .oneshot(request(
            "POST",
            &format!("/channels/{channel_id}/messages"),
            Some(&alice_token),
            Some(json!({ "id": uuid::Uuid::now_v7().to_string(), "content": "hello" })),
        ))
        .await
        .unwrap();
    assert_eq!(
        sent.status(),
        axum::http::StatusCode::OK,
        "sending still succeeds with push disabled"
    );

    // Give a wrongly-enabled sender every chance to have fired.
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(mock.call_count(), 0, "a disabled sender made no HTTP call");
}

#[tokio::test]
async fn a_recipient_gets_a_push_and_the_envelope_carries_no_message_content() {
    let (store, channel_id, _guard) = seeded_store().await;
    let (mock, relay_url) = spawn_mock_relay().await;
    let push = PushSender::with_debounce_window_ms(&push_config(&relay_url), SHORT_DEBOUNCE_MS)
        .expect("push sender");

    let app = app(store.clone(), push);
    let (alice_token, _alice_id) = register_user(&store, "alice").await;
    let (bob_token, _bob_id) = register_user(&store, "bob").await;
    let bob_secret = register_push(&app, &bob_token, "bobs-token").await;

    let secret_content = "the launch codes are 8675309, tell nobody";
    let sent = app
        .clone()
        .oneshot(request(
            "POST",
            &format!("/channels/{channel_id}/messages"),
            Some(&alice_token),
            Some(json!({ "id": uuid::Uuid::now_v7().to_string(), "content": secret_content })),
        ))
        .await
        .unwrap();
    assert_eq!(sent.status(), axum::http::StatusCode::OK);
    let sent = json_body(sent).await;
    let message_id = sent["id"].as_str().unwrap().to_owned();

    assert!(
        wait_until(|| mock.call_count() >= 1, WAIT_TIMEOUT).await,
        "the relay was called"
    );
    assert!(mock.saw_bearer("test-relay-key"), "the relay key was sent");

    let messages = mock.all_messages();
    assert_eq!(messages.len(), 1, "exactly bob's device was targeted");
    let msg = &messages[0];
    assert_eq!(msg["platform"], "ios");
    assert_eq!(msg["token"], "bobs-token");
    assert_eq!(msg["kind"], "message");

    let payload = msg["payload"].as_str().unwrap();
    let sealed = BASE64.decode(payload).unwrap();
    let plaintext = bob_secret.unseal(&sealed).expect("unseal with bob's key");
    let plaintext_str = String::from_utf8(plaintext.clone()).unwrap();

    // The envelope carries only routing metadata...
    let envelope: Value = serde_json::from_slice(&plaintext).unwrap();
    assert_eq!(envelope["domain"], "slim-m.push.v1");
    assert_eq!(envelope["version"], 1);
    assert_eq!(envelope["kind"], "message");
    assert_eq!(envelope["channel_id"], channel_id.to_string());
    assert_eq!(envelope["message_id"], message_id);
    assert_eq!(envelope["seq"], 1);
    assert!(
        envelope["sent_at"].as_i64().is_some(),
        "sent_at rides even on a content-free envelope; see push/envelope.rs"
    );
    // ...and only that: exactly these seven keys, nothing extra smuggled in.
    let keys: std::collections::BTreeSet<_> =
        envelope.as_object().unwrap().keys().cloned().collect();
    let expected: std::collections::BTreeSet<_> = [
        "domain",
        "version",
        "kind",
        "channel_id",
        "message_id",
        "seq",
        "sent_at",
    ]
    .into_iter()
    .map(String::from)
    .collect();
    assert_eq!(keys, expected);

    // ...and definitely never the message text or the author's name.
    assert!(!plaintext_str.contains("launch codes"));
    assert!(!plaintext_str.contains("alice"));
    assert!(!plaintext_str.contains("general"));
}

#[tokio::test]
async fn an_unregistered_result_clears_the_registration() {
    let (store, channel_id, _guard) = seeded_store().await;
    let (mock, relay_url) = spawn_mock_relay().await;
    let push = PushSender::with_debounce_window_ms(&push_config(&relay_url), SHORT_DEBOUNCE_MS)
        .expect("push sender");

    let app = app(store.clone(), push);
    let (alice_token, _alice_id) = register_user(&store, "alice").await;
    let (bob_token, bob_id) = register_user(&store, "bob").await;
    register_push(&app, &bob_token, "bobs-dead-token").await;
    mock.set_status("bobs-dead-token", "unregistered");

    let bob_id = slimm_server::ids::UserId(uuid::Uuid::parse_str(&bob_id).unwrap());
    assert_eq!(store.push_targets(&[bob_id]).await.unwrap().len(), 1);

    app.clone()
        .oneshot(request(
            "POST",
            &format!("/channels/{channel_id}/messages"),
            Some(&alice_token),
            Some(json!({ "id": uuid::Uuid::now_v7().to_string(), "content": "hi bob" })),
        ))
        .await
        .unwrap();

    assert!(
        wait_until_async(
            || async { store.push_targets(&[bob_id]).await.unwrap().is_empty() },
            WAIT_TIMEOUT
        )
        .await,
        "the dead registration was cleared"
    );
}

#[tokio::test]
async fn a_foreground_device_is_not_pushed() {
    let (store, channel_id, _guard) = seeded_store().await;
    let (mock, relay_url) = spawn_mock_relay().await;
    let push = PushSender::with_debounce_window_ms(&push_config(&relay_url), SHORT_DEBOUNCE_MS)
        .expect("push sender");

    let app = app(store.clone(), push);
    let (alice_token, _alice_id) = register_user(&store, "alice").await;

    let (bob_token, _bob_id) = register_user(&store, "bob").await;
    register_push(&app, &bob_token, "bobs-token").await;
    let reported = app
        .clone()
        .oneshot(request(
            "PUT",
            "/push/lifecycle",
            Some(&bob_token),
            Some(json!({ "state": "foreground" })),
        ))
        .await
        .unwrap();
    assert_eq!(reported.status(), axum::http::StatusCode::NO_CONTENT);

    let (carol_token, _carol_id) = register_user(&store, "carol").await;
    register_push(&app, &carol_token, "carols-token").await;
    // Carol never reports a lifecycle state at all, so she is pushed.

    app.clone()
        .oneshot(request(
            "POST",
            &format!("/channels/{channel_id}/messages"),
            Some(&alice_token),
            Some(json!({ "id": uuid::Uuid::now_v7().to_string(), "content": "hi both" })),
        ))
        .await
        .unwrap();

    assert!(
        wait_until(|| mock.call_count() >= 1, WAIT_TIMEOUT).await,
        "the relay was called for carol"
    );
    // Give a wrongly-included bob every chance to have shown up too.
    tokio::time::sleep(Duration::from_millis(200)).await;

    let messages = mock.all_messages();
    assert_eq!(
        messages.len(),
        1,
        "only the non-foreground device was pushed"
    );
    assert_eq!(messages[0]["token"], "carols-token");
}

// Five sends must land inside the window even on a loaded CI runner; 150ms did not.
const BURST_WINDOW_MS: i64 = 1_000;

#[tokio::test]
async fn a_burst_of_messages_in_one_channel_debounces_to_one_push() {
    let (store, channel_id, _guard) = seeded_store().await;
    let (mock, relay_url) = spawn_mock_relay().await;
    let push = PushSender::with_debounce_window_ms(&push_config(&relay_url), BURST_WINDOW_MS)
        .expect("push sender");

    let app = app(store.clone(), push);
    let (alice_token, _alice_id) = register_user(&store, "alice").await;
    let (bob_token, _bob_id) = register_user(&store, "bob").await;
    register_push(&app, &bob_token, "bobs-token").await;

    let send = |content: &str| {
        request(
            "POST",
            &format!("/channels/{channel_id}/messages"),
            Some(&alice_token),
            Some(json!({ "id": uuid::Uuid::now_v7().to_string(), "content": content })),
        )
    };

    // A burst of five messages, well inside the debounce window.
    for i in 0..5 {
        let response = app.clone().oneshot(send(&format!("m{i}"))).await.unwrap();
        assert_eq!(response.status(), axum::http::StatusCode::OK);
    }

    assert!(
        wait_until(|| mock.call_count() >= 1, WAIT_TIMEOUT).await,
        "the first message's push fired"
    );
    // Settle well past the debounce window, then confirm the burst collapsed.
    tokio::time::sleep(Duration::from_millis((BURST_WINDOW_MS * 2) as u64)).await;
    assert_eq!(mock.call_count(), 1, "the burst collapsed into one push");

    // A message after the window has fully elapsed opens a new window.
    let response = app.clone().oneshot(send("later")).await.unwrap();
    assert_eq!(response.status(), axum::http::StatusCode::OK);
    assert!(
        wait_until(|| mock.call_count() >= 2, WAIT_TIMEOUT).await,
        "a message past the debounce window fires again"
    );
}

/// Regression: the debounce used to record its window at decision time, before
/// delivery was even attempted, so a leading trigger that failed at the
/// transport level still spent the window and the next message's push was
/// dropped rather than merely collapsed into it.
#[tokio::test]
async fn a_relay_failure_does_not_swallow_the_next_messages_wake() {
    let (store, channel_id, _guard) = seeded_store().await;
    let (mock, relay_url) = spawn_mock_relay().await;
    let push = PushSender::with_debounce_window_ms(&push_config(&relay_url), SHORT_DEBOUNCE_MS)
        .expect("push sender");

    let app = app(store.clone(), push);
    let (alice_token, _alice_id) = register_user(&store, "alice").await;
    let (bob_token, _bob_id) = register_user(&store, "bob").await;
    register_push(&app, &bob_token, "bobs-token").await;

    let send = |content: &str| {
        request(
            "POST",
            &format!("/channels/{channel_id}/messages"),
            Some(&alice_token),
            Some(json!({ "id": uuid::Uuid::now_v7().to_string(), "content": content })),
        )
    };

    // The leading message's relay call fails outright.
    mock.fail_next_calls(1);
    let sent = app.clone().oneshot(send("first")).await.unwrap();
    assert_eq!(
        sent.status(),
        axum::http::StatusCode::OK,
        "the send still succeeds even though its push attempt fails"
    );
    assert!(
        wait_until(|| mock.attempt_count() >= 1, WAIT_TIMEOUT).await,
        "the first, failing relay call was attempted"
    );
    assert_eq!(mock.call_count(), 0, "it did not actually deliver anything");

    // A second message, well inside the debounce window, must still reach the relay.
    let sent = app.clone().oneshot(send("second")).await.unwrap();
    assert_eq!(sent.status(), axum::http::StatusCode::OK);
    assert!(
        wait_until(|| mock.call_count() >= 1, WAIT_TIMEOUT).await,
        "the second message's push must not be eaten by the failed leading trigger"
    );
    let messages = mock.all_messages();
    assert_eq!(messages.len(), 1);
    assert_eq!(messages[0]["token"], "bobs-token");
}

/// Regression: the debounce used to be keyed on channel id alone, so one
/// recipient's open window silenced every other recipient's first wake in the
/// same channel too.
///
/// Both accounts are fully registered for push up front, so nothing here
/// depends on exactly when either background delivery task happens to run its
/// own database reads. Carol's first message is awaited all the way through
/// delivery before bob's state changes and the second message is sent, so which
/// task's debounce check would happen to run first is never in question; the
/// debounce window is generously larger than the one cheap, hash-free lifecycle
/// call in between, so it cannot elapse on its own by coincidence either.
#[tokio::test]
async fn one_recipients_open_debounce_window_does_not_suppress_another_recipient() {
    const ISOLATION_DEBOUNCE_MS: i64 = 3_000;

    let (store, channel_id, _guard) = seeded_store().await;
    let (mock, relay_url) = spawn_mock_relay().await;
    let push = PushSender::with_debounce_window_ms(&push_config(&relay_url), ISOLATION_DEBOUNCE_MS)
        .expect("push sender");

    let app = app(store.clone(), push);
    let (alice_token, _alice_id) = register_user(&store, "alice").await;
    let (bob_token, _bob_id) = register_user(&store, "bob").await;
    register_push(&app, &bob_token, "bobs-token").await;
    let (carol_token, _carol_id) = register_user(&store, "carol").await;
    register_push(&app, &carol_token, "carols-token").await;

    let report_bob = |state: &str| {
        request(
            "PUT",
            "/push/lifecycle",
            Some(&bob_token),
            Some(json!({ "state": state })),
        )
    };
    let send = |content: &str| {
        request(
            "POST",
            &format!("/channels/{channel_id}/messages"),
            Some(&alice_token),
            Some(json!({ "id": uuid::Uuid::now_v7().to_string(), "content": content })),
        )
    };

    // Bob is foreground, so the first message reaches only carol; her debounce window is waited out fully first.
    let reported = app.clone().oneshot(report_bob("foreground")).await.unwrap();
    assert_eq!(reported.status(), axum::http::StatusCode::NO_CONTENT);
    app.clone().oneshot(send("m1")).await.unwrap();
    assert!(
        wait_until(|| mock.call_count() >= 1, WAIT_TIMEOUT).await,
        "carol's push for the first message fired"
    );
    assert_eq!(mock.all_messages().len(), 1);
    assert_eq!(mock.all_messages()[0]["token"], "carols-token");

    // Bob's phone wakes up, still inside carol's open window, and alice sends a second message.
    let reported = app.clone().oneshot(report_bob("background")).await.unwrap();
    assert_eq!(reported.status(), axum::http::StatusCode::NO_CONTENT);
    app.clone().oneshot(send("m2")).await.unwrap();

    // Bob's first wake must not be swallowed by carol's window: debouncing collapses a burst, not another recipient.
    assert!(
        wait_until(
            || mock
                .all_messages()
                .iter()
                .any(|m| m["token"] == "bobs-token"),
            WAIT_TIMEOUT
        )
        .await,
        "bob's notification must not be suppressed by carol's debounce window"
    );
}
