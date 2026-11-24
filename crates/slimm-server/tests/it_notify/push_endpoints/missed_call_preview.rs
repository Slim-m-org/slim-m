// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The push that makes a missed call visible says a call was missed.

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use crypto_box::SecretKey;
use crypto_box::aead::OsRng;
use serde_json::{Value, json};
use slimm_server::hub::Hub;
use slimm_server::push::PushSender;
use slimm_server::sweep_stale_call_rings_at;
use slimm_server::voice::RING_TIMEOUT;
use tower::ServiceExt;

use crate::push_endpoints::harness::{
    SHORT_DEBOUNCE_MS, WAIT_TIMEOUT, app_with_voice, push_config, register_user, request,
    seeded_store, spawn_mock_relay, wait_until,
};
use crate::push_endpoints::missed_call::{join, open_dm, voice};

async fn register_with_content(app: &axum::Router, token: &str, push_token: &str) -> SecretKey {
    let secret = SecretKey::generate(&mut OsRng);
    let response = app
        .clone()
        .oneshot(request(
            "PUT",
            "/push",
            Some(token),
            Some(json!({
                "platform": "android",
                "push_token": push_token,
                "push_public_key": BASE64.encode(secret.public_key().as_bytes()),
                "include_content": true,
                "include_content_chosen": true,
            })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), axum::http::StatusCode::NO_CONTENT);
    secret
}

#[tokio::test]
async fn a_missed_call_push_previews_as_a_missed_call() {
    let (store, _channel, _guard) = seeded_store().await;
    let (mock, relay_url) = spawn_mock_relay().await;
    let push = PushSender::with_debounce_window_ms(&push_config(&relay_url), SHORT_DEBOUNCE_MS)
        .expect("relay config is valid");
    let voice = voice();
    let hub = Hub::new();
    let app = app_with_voice(store.clone(), push.clone(), voice.clone(), hub.clone());
    let (alice_token, _) = register_user(&store, "alice").await;
    let (bob_token, bob_id) = register_user(&store, "bob").await;
    let secret = register_with_content(&app, &bob_token, "bobs-token").await;

    let channel_id = open_dm(&app, &alice_token, &bob_id).await;
    join(&app, &channel_id, &alice_token).await;
    let rang = app
        .clone()
        .oneshot(request(
            "POST",
            &format!("/channels/{channel_id}/voice/ring"),
            Some(&alice_token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(rang.status(), axum::http::StatusCode::OK);
    assert!(wait_until(|| mock.call_count() > 0, WAIT_TIMEOUT).await);

    sweep_stale_call_rings_at(
        &voice,
        &hub,
        &store,
        &push,
        std::time::Instant::now() + RING_TIMEOUT,
    )
    .await;

    let missed_call_body = || {
        mock.all_messages()
            .iter()
            .filter(|m| m["kind"] == "message" && m["token"] == "bobs-token")
            .filter_map(|m| {
                let sealed = BASE64.decode(m["payload"].as_str()?).ok()?;
                let plain = secret.unseal(&sealed).ok()?;
                serde_json::from_slice::<Value>(&plain).ok()?["body"]
                    .as_str()
                    .map(str::to_owned)
            })
            .next()
    };
    assert!(wait_until(|| missed_call_body().is_some(), WAIT_TIMEOUT).await);
    assert_eq!(missed_call_body().as_deref(), Some("Missed call"));
}
