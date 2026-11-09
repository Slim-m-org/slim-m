// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `lib.rs`'s own `sweep_stale_voice_calls_at`, driven directly against a
//! fake room service that records what it receives, so a heartbeat going
//! stale is proven to reach a real `RemoveParticipant` call rather than only
//! a status code. Nothing before this exercised the sweep and eviction
//! together at all: a sweep wired to a different `VoiceService` clone would
//! have passed every other test in this crate.

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use axum::Router;
use axum::extract::State;
use axum::http::StatusCode;
use axum::routing::post;
use serde_json::json;
use slimm_server::hub::{Event, Hub};
use slimm_server::ids::{ChannelId, UserId};
use slimm_server::voice::VoiceService;
use tokio::net::TcpListener;

mod support;

use support::fake_sfu::{RecordingRoomService, spawn_sfu};

fn voice_at(url: &str) -> VoiceService {
    VoiceService::for_test(url, "APIkey", "a-secret-at-least-32-chars-long!")
}

#[tokio::test]
async fn a_stale_heartbeat_reaches_a_real_remove_participant_call() {
    let recorder = RecordingRoomService::default();
    let url = spawn_sfu(recorder.clone()).await;
    let voice = voice_at(&url);
    let hub = Hub::new();

    let user = UserId::generate();
    let channel = ChannelId::generate();
    let start = Instant::now();
    voice.record_heartbeat_at_for_test(user, channel, start);

    // Nothing stale yet: the sweep must find and remove nobody.
    slimm_server::sweep_stale_voice_calls_at(&voice, &hub, start).await;
    assert!(recorder.removed.lock().unwrap().is_empty());
    assert!(voice.has_heartbeat(user, channel));

    // Past the staleness threshold now: the sweep must find and evict it.
    let past = start + Duration::from_secs(41);
    slimm_server::sweep_stale_voice_calls_at(&voice, &hub, past).await;

    let removed = recorder.removed.lock().unwrap();
    assert_eq!(removed.len(), 1, "exactly one participant was evicted");
    assert_eq!(removed[0]["identity"], user.to_string());
    assert_eq!(removed[0]["room"], format!("channel-{channel}"));
}

#[tokio::test]
async fn a_swept_entry_is_forgotten_so_a_later_sweep_does_not_re_evict_it() {
    let recorder = RecordingRoomService::default();
    let url = spawn_sfu(recorder.clone()).await;
    let voice = voice_at(&url);
    let hub = Hub::new();

    let user = UserId::generate();
    let channel = ChannelId::generate();
    let start = Instant::now();
    voice.record_heartbeat_at_for_test(user, channel, start);

    let past = start + Duration::from_secs(41);
    slimm_server::sweep_stale_voice_calls_at(&voice, &hub, past).await;
    slimm_server::sweep_stale_voice_calls_at(&voice, &hub, past + Duration::from_secs(1)).await;

    assert_eq!(
        recorder.removed.lock().unwrap().len(),
        1,
        "remove_participant forgetting its own entry is what stops a second \
         sweep rediscovering, and re-evicting, somebody already gone"
    );
}

#[tokio::test]
async fn a_refreshed_heartbeat_is_never_swept_or_evicted() {
    let recorder = RecordingRoomService::default();
    let url = spawn_sfu(recorder.clone()).await;
    let voice = voice_at(&url);
    let hub = Hub::new();

    let user = UserId::generate();
    let channel = ChannelId::generate();
    let start = Instant::now();
    voice.record_heartbeat_at_for_test(user, channel, start);
    // A real client's next beat, landing before the old deadline.
    voice.record_heartbeat_at_for_test(user, channel, start + Duration::from_secs(20));

    slimm_server::sweep_stale_voice_calls_at(&voice, &hub, start + Duration::from_secs(41)).await;

    assert!(recorder.removed.lock().unwrap().is_empty());
    assert!(voice.has_heartbeat(user, channel));
}

/// [`json`] is only used to shape the recorded body for the assertions
/// above; this pins that the room service really receives what
/// `remove_participant` sends, not a hand-shaped stand-in for it.
#[tokio::test]
async fn the_recorded_call_carries_no_more_than_room_and_identity() {
    let recorder = RecordingRoomService::default();
    let url = spawn_sfu(recorder.clone()).await;
    let voice = voice_at(&url);
    let hub = Hub::new();

    let user = UserId::generate();
    let channel = ChannelId::generate();
    let start = Instant::now();
    voice.record_heartbeat_at_for_test(user, channel, start);
    slimm_server::sweep_stale_voice_calls_at(&voice, &hub, start + Duration::from_secs(60)).await;

    let removed = recorder.removed.lock().unwrap();
    let call = &removed[0];
    assert_eq!(
        call,
        &json!({ "room": format!("channel-{channel}"), "identity": user.to_string() })
    );
}

/// A room service that holds each call open long enough for overlap to be
/// observable, recording the highest number in flight at once. A serial sweep
/// can never push this above one; the fan-out is what lets a burst overlap.
#[derive(Clone, Default)]
struct ConcurrencyProbe {
    in_flight: Arc<AtomicUsize>,
    max_in_flight: Arc<AtomicUsize>,
    total: Arc<AtomicUsize>,
}

async fn probe_remove(State(probe): State<ConcurrencyProbe>) -> StatusCode {
    let now = probe.in_flight.fetch_add(1, Ordering::SeqCst) + 1;
    probe.max_in_flight.fetch_max(now, Ordering::SeqCst);
    probe.total.fetch_add(1, Ordering::SeqCst);
    tokio::time::sleep(Duration::from_millis(50)).await;
    probe.in_flight.fetch_sub(1, Ordering::SeqCst);
    StatusCode::OK
}

async fn spawn_probe(probe: ConcurrencyProbe) -> String {
    let router = Router::new()
        .route(
            "/twirp/livekit.RoomService/RemoveParticipant",
            post(probe_remove),
        )
        .with_state(probe);
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(listener, router).await.unwrap();
    });
    format!("http://{addr}")
}

/// A blip that expires several heartbeats in one tick must not serialise one
/// SFU round trip after another: the removals fan out (SRV6).
#[tokio::test]
async fn a_burst_of_stale_calls_is_evicted_concurrently() {
    let probe = ConcurrencyProbe::default();
    let url = spawn_probe(probe.clone()).await;
    let voice = voice_at(&url);
    let hub = Hub::new();

    let start = Instant::now();
    for _ in 0..5 {
        voice.record_heartbeat_at_for_test(UserId::generate(), ChannelId::generate(), start);
    }

    slimm_server::sweep_stale_voice_calls_at(&voice, &hub, start + Duration::from_secs(41)).await;

    assert_eq!(
        probe.total.load(Ordering::SeqCst),
        5,
        "every stale participant is still removed"
    );
    assert!(
        probe.max_in_flight.load(Ordering::SeqCst) >= 2,
        "the removals overlap rather than running one after another"
    );
}

/// The fan-out is bounded, not unbounded: a large enough burst must not open
/// one connection to the SFU per stale call at once. Pins the ceiling itself,
/// so a regression to unbounded concurrency fails here rather than only
/// slowing a huge deployment. The 16 mirrors `STALE_SWEEP_CONCURRENCY` in
/// `lib.rs`, which is private to the crate.
#[tokio::test]
async fn the_concurrent_eviction_stays_under_a_ceiling() {
    let probe = ConcurrencyProbe::default();
    let url = spawn_probe(probe.clone()).await;
    let voice = voice_at(&url);
    let hub = Hub::new();

    let start = Instant::now();
    for _ in 0..40 {
        voice.record_heartbeat_at_for_test(UserId::generate(), ChannelId::generate(), start);
    }

    slimm_server::sweep_stale_voice_calls_at(&voice, &hub, start + Duration::from_secs(41)).await;

    assert_eq!(probe.total.load(Ordering::SeqCst), 40, "all 40 are removed");
    let peak = probe.max_in_flight.load(Ordering::SeqCst);
    assert!(peak >= 2, "the removals overlap");
    assert!(
        peak <= 16,
        "never more than the ceiling in flight at once, got {peak}"
    );
}

/// A bystander must learn a stale call ended, not only the SFU: the sweep
/// is one of the three publish sites for `Event::VoiceActivityChanged`
/// (`http/voice.rs`'s `heartbeat` and `forget_heartbeat` are the other two).
#[tokio::test]
async fn a_swept_stale_heartbeat_publishes_voice_activity_changed() {
    let recorder = RecordingRoomService::default();
    let url = spawn_sfu(recorder.clone()).await;
    let voice = voice_at(&url);
    let hub = Hub::new();
    let mut rx = hub.subscribe();

    let user = UserId::generate();
    let channel = ChannelId::generate();
    let start = Instant::now();
    voice.record_heartbeat_at_for_test(user, channel, start);

    // Nothing stale yet, so nothing to publish either.
    slimm_server::sweep_stale_voice_calls_at(&voice, &hub, start).await;
    assert!(rx.try_recv().is_err());

    let past = start + Duration::from_secs(41);
    slimm_server::sweep_stale_voice_calls_at(&voice, &hub, past).await;

    match rx.try_recv().expect("the sweep must publish on eviction") {
        Event::VoiceActivityChanged { channel_id } => assert_eq!(channel_id, channel),
        other => panic!("expected VoiceActivityChanged, got {other:?}"),
    }
}
