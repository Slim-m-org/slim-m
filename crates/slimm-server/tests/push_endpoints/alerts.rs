// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The relay kind a push goes out as, for the alerts that are not a plain message: a
//! mention, and a sign-in from a new device.

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::push::PushSender;
use tower::ServiceExt;

use crate::call_signals::register_device;
use crate::harness::{
    SHORT_DEBOUNCE_MS, WAIT_TIMEOUT, app, json_body, push_config, register_user, request,
    seeded_store, spawn_mock_relay, wait_until,
};

const PASSWORD: &str = "correct horse battery staple";

fn kinds_by_token(messages: &[Value]) -> Vec<(String, String)> {
    let mut pairs: Vec<_> = messages
        .iter()
        .map(|m| {
            let field = |k: &str| m[k].as_str().unwrap_or_default().to_owned();
            (field("token"), field("kind"))
        })
        .collect();
    pairs.sort();
    pairs
}

#[tokio::test]
async fn a_mentioned_recipient_is_pushed_a_mention_and_everyone_else_a_message() {
    let (store, channel_id, _guard) = seeded_store().await;
    let (mock, relay_url) = spawn_mock_relay().await;
    let push = PushSender::with_debounce_window_ms(&push_config(&relay_url), SHORT_DEBOUNCE_MS)
        .expect("relay config is valid");
    let app = app(store.clone(), push);
    let (alice_token, _) = register_user(&store, "alice").await;
    let (bob_token, _) = register_user(&store, "bob").await;
    let (carol_token, _) = register_user(&store, "carol").await;
    register_device(&app, &bob_token, "android", "bob-fcm", None).await;
    register_device(&app, &carol_token, "ios", "carol-apns", None).await;

    let sent = app
        .clone()
        .oneshot(request(
            "POST",
            &format!("/channels/{channel_id}/messages"),
            Some(&alice_token),
            Some(json!({ "id": uuid::Uuid::now_v7().to_string(), "content": "hi @bob" })),
        ))
        .await
        .unwrap();
    assert_eq!(sent.status(), axum::http::StatusCode::OK);

    assert!(wait_until(|| mock.all_messages().len() >= 2, WAIT_TIMEOUT).await);
    assert_eq!(
        kinds_by_token(&mock.all_messages()),
        vec![
            ("bob-fcm".to_owned(), "mention".to_owned()),
            ("carol-apns".to_owned(), "message".to_owned()),
        ]
    );
}

async fn login(app: &axum::Router, device_name: &str) -> String {
    let response = app
        .clone()
        .oneshot(request(
            "POST",
            "/auth/login",
            None,
            Some(json!({
                "username": "alice",
                "password": PASSWORD,
                "device_name": device_name,
                "client_kind": "android",
            })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), axum::http::StatusCode::OK);
    json_body(response).await["access_token"]
        .as_str()
        .unwrap()
        .to_owned()
}

#[tokio::test]
async fn a_new_device_sign_in_alerts_the_accounts_other_devices() {
    let (store, _channel, _guard) = seeded_store().await;
    let (mock, relay_url) = spawn_mock_relay().await;
    let push = PushSender::with_debounce_window_ms(&push_config(&relay_url), SHORT_DEBOUNCE_MS)
        .expect("relay config is valid");
    let app = app(store.clone(), push);
    let hash = Auth::new(2)
        .unwrap()
        .hash_password(PASSWORD.to_owned())
        .await
        .unwrap();
    let alice = store.create_account("alice", "alice", &hash).await.unwrap();
    store.bootstrap_deployment(alice.id).await.unwrap();

    let pixel = login(&app, "Pixel").await;
    let pixel_secret = register_device(&app, &pixel, "android", "alice-pixel", None).await;
    let tablet = login(&app, "Tablet").await;
    register_device(&app, &tablet, "ios", "alice-tablet", None).await;
    // The tablet was itself a new device, and its alert reached the pixel.
    assert!(wait_until(|| mock.all_messages().len() == 1, WAIT_TIMEOUT).await);
    let seen_before = mock.all_messages().len();

    login(&app, "Borrowed laptop").await;

    assert!(
        wait_until(
            || mock.all_messages().len() >= seen_before + 2,
            WAIT_TIMEOUT
        )
        .await
    );
    let alerts = &mock.all_messages()[seen_before..];
    assert_eq!(
        kinds_by_token(alerts),
        vec![
            ("alice-pixel".to_owned(), "security".to_owned()),
            ("alice-tablet".to_owned(), "security".to_owned()),
        ]
    );
    let to_pixel = alerts.iter().find(|m| m["token"] == "alice-pixel").unwrap();
    let sealed = BASE64
        .decode(to_pixel["payload"].as_str().unwrap())
        .unwrap();
    let envelope: Value =
        serde_json::from_slice(&pixel_secret.unseal(&sealed).expect("unseal")).unwrap();
    assert_eq!(envelope["kind"], "security");
    assert_eq!(envelope["event"], "new_device_sign_in");
    assert!(
        envelope["sent_at"].as_i64().is_some(),
        "the lock screen refuses a replayed alert only if it can tell when it was sealed: {envelope}"
    );
    assert!(
        envelope.get("device_name").is_none(),
        "a device that did not ask for content is not told the name: {envelope}"
    );
}
