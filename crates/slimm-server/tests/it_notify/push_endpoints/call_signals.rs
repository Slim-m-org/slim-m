// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What a DM ring puts on the wire to the relay, per platform, and what its
//! end sends after it.
//!
//! The relay routes a `call` push on iOS to the app's `.voip` PushKit topic,
//! which only accepts the device's VoIP token, so a ring addressed to the
//! ordinary APNs token can never be delivered.

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use crypto_box::SecretKey;
use crypto_box::aead::rand_core::{OsRng, TryRngCore};
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
use crate::push_endpoints::missed_call::{open_dm, voice};

/// Registers a device for push on `platform`, with a VoIP token when given.
pub(crate) async fn register_device(
    app: &axum::Router,
    token: &str,
    platform: &str,
    push_token: &str,
    voip_push_token: Option<&str>,
) -> SecretKey {
    let secret = SecretKey::generate(&mut OsRng.unwrap_err());
    let response = app
        .clone()
        .oneshot(request(
            "PUT",
            "/push",
            Some(token),
            Some(json!({
                "platform": platform,
                "push_token": push_token,
                "voip_push_token": voip_push_token,
                "push_public_key": BASE64.encode(secret.public_key().as_bytes()),
                "include_content": false,
                "include_content_chosen": true,
            })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), axum::http::StatusCode::NO_CONTENT);
    secret
}

fn with_kind<'a>(messages: &'a [Value], kind: &str) -> Vec<&'a Value> {
    messages.iter().filter(|m| m["kind"] == kind).collect()
}

fn tokens(messages: &[&Value]) -> Vec<String> {
    messages
        .iter()
        .filter_map(|m| m["token"].as_str().map(str::to_owned))
        .collect()
}

struct Call {
    store: slimm_server::store::Store,
    app: axum::Router,
    push: PushSender,
    voice: slimm_server::voice::VoiceService,
    hub: Hub,
    mock: crate::push_endpoints::harness::MockRelay,
    alice_token: String,
    bob_token: String,
    bob: slimm_server::ids::UserId,
    channel_id: String,
    _guard: crate::support::TestDbGuard,
}

async fn call_setup() -> Call {
    let (store, _channel, guard) = seeded_store().await;
    let (mock, relay_url) = spawn_mock_relay().await;
    let push = PushSender::with_debounce_window_ms(&push_config(&relay_url), SHORT_DEBOUNCE_MS)
        .expect("relay config is valid");
    let (voice, hub) = (voice(), Hub::new());
    let app = app_with_voice(store.clone(), push.clone(), voice.clone(), hub.clone());
    let (alice_token, _) = register_user(&store, "alice").await;
    let (bob_token, bob_id) = register_user(&store, "bob").await;
    let channel_id = open_dm(&app, &alice_token, &bob_id).await;
    Call {
        store,
        app,
        push,
        voice,
        hub,
        mock,
        alice_token,
        bob_token,
        bob: slimm_server::ids::UserId(uuid::Uuid::parse_str(&bob_id).unwrap()),
        channel_id,
        _guard: guard,
    }
}

impl Call {
    async fn send(&self, method: &str, path: &str, token: &str) -> axum::http::StatusCode {
        let uri = format!("/channels/{}/voice/{path}", self.channel_id);
        let response = self
            .app
            .clone()
            .oneshot(request(method, &uri, Some(token), None))
            .await
            .unwrap();
        response.status()
    }

    async fn ring(&self) {
        assert_eq!(
            self.send("POST", "ring", &self.alice_token).await,
            axum::http::StatusCode::OK
        );
    }

    async fn wait_for_kind(&self, kind: &str) -> Vec<Value> {
        let seen = wait_until(
            || !with_kind(&self.mock.all_messages(), kind).is_empty(),
            WAIT_TIMEOUT,
        )
        .await;
        assert!(seen, "no {kind} push reached the relay");
        self.mock.all_messages()
    }
}

#[tokio::test]
async fn an_ios_ring_is_addressed_to_the_voip_token() {
    let call = call_setup().await;
    register_device(
        &call.app,
        &call.bob_token,
        "ios",
        "bob-apns",
        Some("bob-voip"),
    )
    .await;

    call.ring().await;

    let messages = call.wait_for_kind("call").await;
    assert_eq!(tokens(&with_kind(&messages, "call")), vec!["bob-voip"]);
}

#[tokio::test]
async fn an_ios_device_without_a_voip_token_is_not_rung_through_its_apns_token() {
    let call = call_setup().await;
    register_device(&call.app, &call.bob_token, "ios", "bob-apns", None).await;
    register_device(&call.app, &call.alice_token, "android", "alice-fcm", None).await;

    call.ring().await;
    // The decline's call_end proves the ring's own push had its chance to fire first.
    call.send("POST", "ring/decline", &call.bob_token).await;
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;

    let rung = tokens(&with_kind(&call.mock.all_messages(), "call"));
    assert!(rung.is_empty(), "rang {rung:?}");
}

#[tokio::test]
async fn an_android_ring_is_addressed_to_the_fcm_token() {
    let call = call_setup().await;
    register_device(&call.app, &call.bob_token, "android", "bob-fcm", None).await;

    call.ring().await;

    let messages = call.wait_for_kind("call").await;
    assert_eq!(tokens(&with_kind(&messages, "call")), vec!["bob-fcm"]);
}

#[tokio::test]
async fn a_dead_voip_token_is_cleared_without_losing_message_pushes() {
    let call = call_setup().await;
    register_device(
        &call.app,
        &call.bob_token,
        "ios",
        "bob-apns",
        Some("bob-voip"),
    )
    .await;
    call.mock.set_status("bob-voip", "unregistered");

    call.ring().await;
    call.wait_for_kind("call").await;

    let voip_of_bob = || async {
        let targets = call.store.push_targets(&[call.bob]).await.unwrap();
        targets[0].voip_push_token.clone()
    };
    let cleared = crate::push_endpoints::harness::wait_until_async(
        || async { voip_of_bob().await.is_none() },
        WAIT_TIMEOUT,
    )
    .await;
    assert!(cleared, "the dead voip token should be cleared");
    let targets = call.store.push_targets(&[call.bob]).await.unwrap();
    assert_eq!(
        targets.first().map(|t| t.push_token.as_str()),
        Some("bob-apns"),
        "the ordinary token still carries message pushes"
    );
}

#[tokio::test]
async fn a_canceled_ring_tells_the_callee_they_missed_a_call() {
    let call = call_setup().await;
    register_device(&call.app, &call.bob_token, "android", "bob-fcm", None).await;
    call.ring().await;
    call.wait_for_kind("call").await;

    call.send("DELETE", "heartbeat", &call.alice_token).await;

    let messages = call.wait_for_kind("message").await;
    assert_eq!(tokens(&with_kind(&messages, "message")), vec!["bob-fcm"]);
}

#[tokio::test]
async fn every_way_a_ring_ends_stops_it_on_the_callees_android_devices() {
    for end in ["decline", "cancel", "timeout"] {
        let call = call_setup().await;
        register_device(&call.app, &call.bob_token, "android", "bob-fcm", None).await;
        register_device(&call.app, &call.alice_token, "android", "alice-fcm", None).await;
        call.ring().await;
        call.wait_for_kind("call").await;

        match end {
            "decline" => {
                call.send("POST", "ring/decline", &call.bob_token).await;
            }
            "cancel" => {
                call.send("DELETE", "heartbeat", &call.alice_token).await;
            }
            _ => {
                let at = std::time::Instant::now() + RING_TIMEOUT;
                sweep_stale_call_rings_at(&call.voice, &call.hub, &call.store, &call.push, at)
                    .await;
            }
        }

        let messages = call.wait_for_kind("call_end").await;
        assert_eq!(
            tokens(&with_kind(&messages, "call_end")),
            vec!["bob-fcm"],
            "{end}: only the callee's device was ringing"
        );
    }
}

#[tokio::test]
async fn a_call_end_is_never_sent_to_ios() {
    let call = call_setup().await;
    register_device(
        &call.app,
        &call.bob_token,
        "ios",
        "bob-apns",
        Some("bob-voip"),
    )
    .await;
    call.ring().await;
    call.wait_for_kind("call").await;

    call.send("POST", "ring/decline", &call.bob_token).await;
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;

    assert!(with_kind(&call.mock.all_messages(), "call_end").is_empty());
}
