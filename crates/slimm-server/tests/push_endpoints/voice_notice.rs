// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A voice notice reaches an opted-in member's backgrounded device as a sealed push the relay
//! sees only as a plain `message`, and never reaches the member who joined (decision 0107).

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use serde_json::{Value, json};
use slimm_server::hub::Hub;
use slimm_server::push::PushSender;
use slimm_server::voice::VoiceService;
use slimm_server::voice_notify::{JoinMode, VoiceNotifyChoice};
use tower::ServiceExt;

use crate::harness::{
    SHORT_DEBOUNCE_MS, WAIT_TIMEOUT, app_with_voice, push_config, register_push, register_user,
    seeded_store, spawn_mock_relay, wait_until,
};
use crate::support::livekit_webhook::webhook_request;

const KEY: &str = "APItestkey";
const SECRET: &str = "a-test-secret-of-at-least-32-characters";

#[tokio::test]
async fn a_join_wakes_an_opted_in_device_with_a_sealed_voice_envelope() {
    let (store, _general, _guard) = seeded_store().await;
    let (mock, relay_url) = spawn_mock_relay().await;
    let push = PushSender::with_debounce_window_ms(&push_config(&relay_url), SHORT_DEBOUNCE_MS)
        .expect("relay config is valid");
    let voice = VoiceService::for_test("wss://livekit.example.com", KEY, SECRET);
    let app = app_with_voice(store.clone(), push, voice, Hub::new());
    let channel = store.create_channel("lounge", "voice").await.unwrap();

    let (alice_token, alice_id) = register_user(&store, "alice").await;
    let (bob_token, bob_id) = register_user(&store, "bob").await;
    let alice_secret = register_push(&app, &alice_token, "alice-phone").await;
    let bob_secret = register_push(&app, &bob_token, "bob-phone").await;
    let every = VoiceNotifyChoice {
        joins: JoinMode::Every,
        streams: false,
    };
    for who in [&alice_id, &bob_id] {
        store
            .set_voice_notify_choice(
                who.parse().map(slimm_server::ids::UserId).unwrap(),
                channel.id,
                every,
            )
            .await
            .unwrap();
    }

    let room = slimm_server::voice::room_for_channel(channel.id);
    let response = app
        .clone()
        .oneshot(webhook_request(
            json!({
                "event": "participant_joined",
                "room": { "name": room },
                "participant": { "identity": alice_id, "sid": "PA_alice" },
            }),
            KEY,
            SECRET,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), 204);

    assert!(wait_until(|| !mock.all_messages().is_empty(), WAIT_TIMEOUT).await);
    let sent = mock.all_messages();
    assert_eq!(
        sent.len(),
        1,
        "only bob is told, never alice about her own join"
    );
    assert_eq!(sent[0]["token"], "bob-phone");
    assert_eq!(
        sent[0]["kind"], "voice",
        "android shows its own line only for its own kind"
    );
    let sealed = BASE64.decode(sent[0]["payload"].as_str().unwrap()).unwrap();
    assert!(alice_secret.unseal(&sealed).is_err(), "sealed to bob alone");
    let envelope: Value = serde_json::from_slice(&bob_secret.unseal(&sealed).unwrap()).unwrap();
    assert_eq!(envelope["kind"], "voice");
    assert_eq!(envelope["activity"], "call_started");
    assert_eq!(envelope["channel_id"], channel.id.to_string());
    assert!(
        envelope.get("actor_name").is_none(),
        "names need the content opt-in"
    );
}
