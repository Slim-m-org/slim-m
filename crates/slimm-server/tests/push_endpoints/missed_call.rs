// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A call nobody answered wakes the person who missed it.
//!
//! The record itself has existed since #1168: the ring sweep writes a durable
//! call row and fans it out, so a missed call was already in the transcript.
//! What it did not do was push, so somebody whose phone was asleep learned
//! about a missed call only by opening the app - which is the one case a missed
//! call notification exists for.
//!
//! Driven through the ring sweep with an explicit clock rather than by waiting
//! out `RING_TIMEOUT`, so this costs milliseconds and cannot flake on a loaded
//! runner.

use std::time::Duration;

use serde_json::Value;
use slimm_server::hub::Hub;
use slimm_server::ids::UserId;
use slimm_server::notification_schedule::{DayWindow, OffHoursMode, WEEKDAYS};
use slimm_server::push::PushSender;
use slimm_server::store::DaySetting;
use slimm_server::sweep_stale_call_rings_at;
use slimm_server::voice::{RING_TIMEOUT, VoiceService};
use tower::ServiceExt;

use crate::call_signals::register_device;
use crate::harness::{
    SHORT_DEBOUNCE_MS, WAIT_TIMEOUT, app_with_voice, json_body, push_config, register_user,
    request, seeded_store, spawn_mock_relay, wait_until,
};

pub(crate) fn voice() -> VoiceService {
    VoiceService::for_test(
        "wss://livekit.example.com",
        "APItestkey",
        "a-test-secret-of-at-least-32-characters",
    )
}

/// Opens the DM between the caller and the callee, returning its channel id.
pub(crate) async fn open_dm(app: &axum::Router, token: &str, target_id: &str) -> String {
    let response = app
        .clone()
        .oneshot(request(
            "POST",
            &format!("/dms/{target_id}"),
            Some(token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), axum::http::StatusCode::OK);
    json_body(response).await["channel_id"]
        .as_str()
        .unwrap()
        .to_owned()
}

/// Every token the relay was asked to wake, across all calls.
fn woken(messages: &[Value]) -> Vec<String> {
    messages
        .iter()
        .filter_map(|m| m["token"].as_str().map(str::to_owned))
        .collect()
}

#[tokio::test]
async fn a_ring_nobody_answered_wakes_the_callee() {
    let (store, _channel, _guard) = seeded_store().await;
    let (mock, relay_url) = spawn_mock_relay().await;
    let push = PushSender::with_debounce_window_ms(&push_config(&relay_url), SHORT_DEBOUNCE_MS)
        .expect("relay config is valid");
    let voice = voice();
    let hub = Hub::new();
    let app = app_with_voice(store.clone(), push.clone(), voice.clone(), hub.clone());

    let (alice_token, _alice_id) = register_user(&store, "alice").await;
    let (bob_token, bob_id) = register_user(&store, "bob").await;
    let _bob_secret = register_device(&app, &bob_token, "android", "bobs-token", None).await;

    let channel_id = open_dm(&app, &alice_token, &bob_id).await;
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

    // The ring pushed already; the one under test is the unanswered one.
    assert!(
        wait_until(|| mock.call_count() > 0, WAIT_TIMEOUT).await,
        "the ring itself should have pushed first"
    );
    let after_ring = mock.call_count();

    sweep_stale_call_rings_at(
        &voice,
        &hub,
        &store,
        &push,
        std::time::Instant::now() + RING_TIMEOUT,
    )
    .await;

    assert!(
        wait_until(|| mock.call_count() > after_ring, WAIT_TIMEOUT).await,
        "the missed call should have pushed too, and nothing else fires here"
    );
    assert!(
        woken(&mock.all_messages()).contains(&"bobs-token".to_owned()),
        "the person who missed the call is the one woken"
    );
    // The call-end signal alone moves the call count, so the transcript row's own wake is asserted by kind.
    let woke_as_message = || {
        mock.all_messages()
            .iter()
            .any(|m| m["kind"] == "message" && m["token"] == "bobs-token")
    };
    assert!(
        wait_until(woke_as_message, WAIT_TIMEOUT).await,
        "the missed call must wake the callee as a message, not only as a call-end signal"
    );
}

/// The caller is not woken by their own unanswered call. `notify_message`
/// already excludes an author from their own message's recipients, and routing
/// the missed call through it is what gets that for free - a kind of its own
/// would have had to remember.
#[tokio::test]
async fn the_caller_is_not_woken_by_their_own_missed_call() {
    let (store, _channel, _guard) = seeded_store().await;
    let (mock, relay_url) = spawn_mock_relay().await;
    let push = PushSender::with_debounce_window_ms(&push_config(&relay_url), SHORT_DEBOUNCE_MS)
        .expect("relay config is valid");
    let voice = voice();
    let hub = Hub::new();
    let app = app_with_voice(store.clone(), push.clone(), voice.clone(), hub.clone());

    let (alice_token, alice_id) = register_user(&store, "alice").await;
    let (bob_token, bob_id) = register_user(&store, "bob").await;
    // Both registered, so "only the callee" is a result, not a missing device.
    let _alice_secret = register_device(&app, &alice_token, "android", "alices-token", None).await;
    let _bob_secret = register_device(&app, &bob_token, "android", "bobs-token", None).await;

    let channel_id = open_dm(&app, &alice_token, &bob_id).await;
    app.clone()
        .oneshot(request(
            "POST",
            &format!("/channels/{channel_id}/voice/ring"),
            Some(&alice_token),
            None,
        ))
        .await
        .unwrap();
    assert!(wait_until(|| mock.call_count() > 0, WAIT_TIMEOUT).await);
    let before = mock.all_messages().len();

    sweep_stale_call_rings_at(
        &voice,
        &hub,
        &store,
        &push,
        std::time::Instant::now() + RING_TIMEOUT,
    )
    .await;
    assert!(wait_until(|| mock.all_messages().len() > before, WAIT_TIMEOUT).await);

    let from_the_sweep = woken(&mock.all_messages()[before..]);
    assert!(
        from_the_sweep.contains(&"bobs-token".to_owned()),
        "the callee is woken: {from_the_sweep:?}"
    );
    assert!(
        !from_the_sweep.contains(&"alices-token".to_owned()),
        "the caller already knows nobody answered: {from_the_sweep:?}"
    );
    assert_eq!(alice_id.len(), bob_id.len(), "both ids are real users");
}

/// A disabled sender stays a true no-op on this path too, so a deployment with
/// no relay configured is not quietly making HTTP calls from a sweep.
#[tokio::test]
async fn a_disabled_sender_pushes_nothing_for_a_missed_call() {
    let (store, _channel, _guard) = seeded_store().await;
    let (mock, _relay_url) = spawn_mock_relay().await;
    let voice = voice();
    let hub = Hub::new();
    let app = app_with_voice(
        store.clone(),
        PushSender::disabled(),
        voice.clone(),
        hub.clone(),
    );

    let (alice_token, _alice_id) = register_user(&store, "alice").await;
    let (bob_token, bob_id) = register_user(&store, "bob").await;
    let _bob_secret = register_device(&app, &bob_token, "android", "bobs-token", None).await;
    let channel_id = open_dm(&app, &alice_token, &bob_id).await;
    app.clone()
        .oneshot(request(
            "POST",
            &format!("/channels/{channel_id}/voice/ring"),
            Some(&alice_token),
            None,
        ))
        .await
        .unwrap();

    sweep_stale_call_rings_at(
        &voice,
        &hub,
        &store,
        &PushSender::disabled(),
        std::time::Instant::now() + RING_TIMEOUT,
    )
    .await;

    // Give a wrongly-enabled sender every chance to have fired.
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(mock.call_count(), 0);
}

/// A call rings straight through an active off-hours schedule in `nothing`
/// mode, exactly as it always ignored the old quiet-hours window -
/// `push::call_ring::deliver`'s own doc comment names this as the one
/// Slack-style exception the schedule makes.
#[tokio::test]
async fn a_ring_still_wakes_the_callee_in_off_hours_nothing_mode() {
    let (store, _channel, _guard) = seeded_store().await;
    let (mock, relay_url) = spawn_mock_relay().await;
    let push = PushSender::with_debounce_window_ms(&push_config(&relay_url), SHORT_DEBOUNCE_MS)
        .expect("relay config is valid");
    let voice = voice();
    let hub = Hub::new();
    let app = app_with_voice(store.clone(), push.clone(), voice.clone(), hub.clone());

    let (alice_token, _alice_id) = register_user(&store, "alice").await;
    let (bob_token, bob_id) = register_user(&store, "bob").await;
    let _bob_secret = register_device(&app, &bob_token, "android", "bobs-token", None).await;

    let bob = UserId(uuid::Uuid::parse_str(&bob_id).unwrap());
    // A ten-minute window well away from now, so "now" is guaranteed off hours.
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64;
    let now_minute = (now_ms / 60_000) % 1440;
    let wrap = |m: i64| m.rem_euclid(1440);
    let window = DayWindow::parse(wrap(now_minute + 15), wrap(now_minute + 25)).unwrap();
    let off_hours = (0..WEEKDAYS as u8)
        .map(|weekday| DaySetting { weekday, window })
        .collect::<Vec<_>>();
    store
        .set_notification_schedule(bob, "UTC", OffHoursMode::Nothing, &off_hours)
        .await
        .unwrap();

    let channel_id = open_dm(&app, &alice_token, &bob_id).await;
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

    assert!(
        wait_until(|| mock.call_count() > 0, WAIT_TIMEOUT).await,
        "a ring must wake the callee even while their schedule reads off hours in nothing mode"
    );
    assert!(woken(&mock.all_messages()).contains(&"bobs-token".to_owned()));
}
