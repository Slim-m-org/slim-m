// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What startup does to voice sessions beyond closing them: modules hear about the closes, and a
//! call the SFU would not answer for gets its sessions back on the next heartbeat.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use axum::Router;
use axum::http::StatusCode;
use axum::routing::post;
use serde_json::json;
use slimm_server::hub::{Event, Hub};
use slimm_server::ids::ChannelId;
use slimm_server::voice::VoiceService;
use tokio::net::TcpListener;
use tower::ServiceExt;

use crate::support;
use support::app::{register_id_token, request_bare};

const API_KEY: &str = "APItestkey";
const API_SECRET: &str = "a-test-secret-of-at-least-32-characters";

/// A room service listing `member` as `sid` on every room, unless `down` is set and it answers 500.
async fn sfu(down: Arc<AtomicBool>, member: String, sid: &'static str) -> String {
    slow_sfu(down, member, sid, std::time::Duration::ZERO).await
}

/// [`sfu`] whose roster answer takes `delay`.
async fn slow_sfu(
    down: Arc<AtomicBool>,
    member: String,
    sid: &'static str,
    delay: std::time::Duration,
) -> String {
    let list = move || {
        let (down, member) = (down.clone(), member.clone());
        async move {
            tokio::time::sleep(delay).await;
            if down.load(Ordering::SeqCst) {
                return Err(StatusCode::INTERNAL_SERVER_ERROR);
            }
            let who = json!({ "identity": member, "sid": sid, "name": "n", "tracks": [] });
            Ok(axum::Json(json!({ "participants": [who] })))
        }
    };
    let router = Router::new().route("/twirp/livekit.RoomService/ListParticipants", post(list));
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(listener, router).await.unwrap();
    });
    format!("http://{addr}")
}

#[tokio::test]
async fn startup_tells_subscribers_which_sessions_it_closed() {
    let (store, _guard) = support::new_store("slimm-vs-startup-publish").await;
    let (user, _) = register_id_token(&store, "nia").await;
    let channel = store.create_channel("voice", "voice").await.unwrap().id;
    store
        .open_voice_session(channel, user, "PA_1", 1)
        .await
        .unwrap();
    let hub = Hub::new();
    let mut events = hub.subscribe();
    let voice = VoiceService::for_test("http://127.0.0.1:1", API_KEY, API_SECRET);

    slimm_server::reconcile_on_startup(&store, &voice, &hub).await;

    match events.try_recv() {
        Ok(Event::VoiceSessionClosed {
            user_id,
            channel_id,
            ..
        }) => assert_eq!((user_id, channel_id), (user, channel)),
        other => panic!("no close was published: {other:?}"),
    }
}

#[tokio::test]
async fn a_call_the_sfu_did_not_answer_for_reopens_on_the_next_heartbeat() {
    let (store, _guard) = support::new_store("slimm-vs-startup-defer").await;
    let (user, token) = register_id_token(&store, "nia").await;
    let channel = store.create_channel("voice", "voice").await.unwrap().id;
    store
        .open_voice_session(channel, user, "PA_1", 1)
        .await
        .unwrap();
    let down = Arc::new(AtomicBool::new(true));
    let url = sfu(down.clone(), user.to_string(), "PA_1").await;
    let voice = VoiceService::for_test(&url, API_KEY, API_SECRET);
    let hub = Hub::new();
    let app = support::app::builder(store.clone())
        .voice(voice.clone())
        .hub(hub.clone())
        .router();

    slimm_server::reconcile_on_startup(&store, &voice, &hub).await;
    assert!(
        store
            .channels_with_open_voice_sessions()
            .await
            .unwrap()
            .is_empty()
    );

    down.store(false, Ordering::SeqCst);
    let beat = app
        .oneshot(request_bare(
            "POST",
            &format!("/channels/{channel}/voice/heartbeat"),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(beat.status(), StatusCode::NO_CONTENT);

    wait_for_open_session(&store, channel).await;
}

async fn wait_for_open_session(store: &slimm_server::store::Store, channel: ChannelId) {
    for _ in 0..100 {
        if store.channels_with_open_voice_sessions().await.unwrap() == vec![channel] {
            return;
        }
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
    panic!("the member on the call had no session");
}

#[tokio::test]
async fn the_sweep_reopens_a_call_nobody_beat_for() {
    let (store, _guard) = support::new_store("slimm-vs-startup-retry").await;
    let (user, _) = register_id_token(&store, "nia").await;
    let channel = store.create_channel("voice", "voice").await.unwrap().id;
    store
        .open_voice_session(channel, user, "PA_1", 1)
        .await
        .unwrap();
    let down = Arc::new(AtomicBool::new(true));
    let url = sfu(down.clone(), user.to_string(), "PA_1").await;
    let voice = VoiceService::for_test(&url, API_KEY, API_SECRET);
    let hub = Hub::new();
    slimm_server::reconcile_on_startup(&store, &voice, &hub).await;

    slimm_server::retry_deferred_reopens(&store, &voice).await;
    assert!(
        store
            .channels_with_open_voice_sessions()
            .await
            .unwrap()
            .is_empty(),
        "an SFU that is still down opens nothing"
    );

    down.store(false, Ordering::SeqCst);
    slimm_server::retry_deferred_reopens(&store, &voice).await;

    wait_for_open_session(&store, channel).await;
}

#[tokio::test]
async fn a_slow_sfu_does_not_hold_up_the_first_heartbeat() {
    let (store, _guard) = support::new_store("slimm-vs-startup-slow").await;
    let (user, token) = register_id_token(&store, "nia").await;
    let channel = store.create_channel("voice", "voice").await.unwrap().id;
    store
        .open_voice_session(channel, user, "PA_1", 1)
        .await
        .unwrap();
    let down = Arc::new(AtomicBool::new(true));
    let slow = std::time::Duration::from_millis(1200);
    let url = slow_sfu(down.clone(), user.to_string(), "PA_1", slow).await;
    let voice = VoiceService::for_test(&url, API_KEY, API_SECRET);
    let hub = Hub::new();
    let app = support::app::builder(store.clone())
        .voice(voice.clone())
        .hub(hub.clone())
        .router();
    slimm_server::reconcile_on_startup(&store, &voice, &hub).await;
    down.store(false, Ordering::SeqCst);

    let started = std::time::Instant::now();
    let beat = app
        .oneshot(request_bare(
            "POST",
            &format!("/channels/{channel}/voice/heartbeat"),
            Some(&token),
        ))
        .await
        .unwrap();

    assert_eq!(beat.status(), StatusCode::NO_CONTENT);
    assert!(started.elapsed() < std::time::Duration::from_millis(600));
}
