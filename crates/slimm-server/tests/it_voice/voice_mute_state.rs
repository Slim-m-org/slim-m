// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Who is muted or deafened, as someone outside the call sees it: the roster reads it off the
//! SFU, and a mute or deafen report has every viewer of the channel read it again.

use std::time::{Duration, Instant};

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::hub::{Event, Hub};
use slimm_server::ids::{ChannelId, UserId};
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use slimm_server::voice::VoiceService;
use tokio::sync::broadcast::Receiver;
use tower::ServiceExt;

use crate::support;
use support::app::{Account, call_as, register_account};
use support::fake_sfu::{RecordingRoomService, spawn_sfu};
use support::livekit_webhook::webhook_request;

const API_KEY: &str = "key";
const API_SECRET: &str = "a-secret-at-least-32-chars-long!";

struct World {
    store: Store,
    recorder: RecordingRoomService,
    voice: VoiceService,
    hub: Hub,
    app: Router,
    alice: Account,
    bob: Account,
    channel: ChannelId,
    _guard: support::TestDbGuard,
}

async fn world(prefix: &str) -> World {
    let recorder = RecordingRoomService::default();
    let url = spawn_sfu(recorder.clone()).await;
    let (store, guard) = support::new_store(prefix).await;
    let alice = register_account(&store, "alice").await;
    let bob = register_account(&store, "bob").await;
    let channel = store.create_channel("lounge", "voice").await.unwrap().id;
    let voice = VoiceService::for_test(&url, API_KEY, API_SECRET);
    let hub = Hub::new();
    let app = support::app::builder(store.clone())
        .voice(voice.clone())
        .hub(hub.clone())
        .router();
    World {
        store,
        recorder,
        voice,
        hub,
        app,
        alice,
        bob,
        channel,
        _guard: guard,
    }
}

fn entry(user: UserId, mic_muted: bool, deafened: bool) -> Value {
    let attributes = if deafened {
        json!({ "deafened": "true" })
    } else {
        json!({})
    };
    json!({
        "identity": user.to_string(),
        "sid": format!("PA_{user}"),
        "state": "ACTIVE",
        "tracks": [{ "type": "AUDIO", "source": "MICROPHONE", "muted": mic_muted }],
        "attributes": attributes,
    })
}

impl World {
    /// `(is_muted, is_deafened)` for `user` in the roster alice reads.
    async fn shown(&self, user: UserId) -> (Value, Value) {
        let uri = format!("/channels/{}/voice/roster", self.channel);
        let (status, body) = call_as(&self.app, "GET", &uri, &self.alice.token, None).await;
        assert_eq!(status, StatusCode::OK, "{body}");
        let row = body["participants"]
            .as_array()
            .unwrap()
            .iter()
            .find(|p| p["user_id"] == user.to_string())
            .cloned()
            .unwrap_or_else(|| panic!("{user} is not in {body}"));
        (row["is_muted"].clone(), row["is_deafened"].clone())
    }

    async fn report(&self, who: &Account, what: &str, on: bool) -> StatusCode {
        let uri = format!("/channels/{}/voice/{what}", self.channel);
        let body = json!({ what: on });
        call_as(&self.app, "PUT", &uri, &who.token, Some(body))
            .await
            .0
    }

    async fn beat(&self, who: &Account) -> StatusCode {
        let uri = format!("/channels/{}/voice/heartbeat", self.channel);
        call_as(&self.app, "POST", &uri, &who.token, None).await.0
    }

    async fn deliver(&self, body: Value) -> StatusCode {
        let request = webhook_request(body, API_KEY, API_SECRET);
        self.app.clone().oneshot(request).await.unwrap().status()
    }
}

fn nudged(rx: &mut Receiver<Event>, channel: ChannelId) -> bool {
    std::iter::from_fn(|| rx.try_recv().ok())
        .any(|event| matches!(event, Event::VoiceActivityChanged { channel_id } if channel_id == channel))
}

#[tokio::test]
async fn the_roster_shows_who_is_muted_and_deafened() {
    let w = world("slimm-mute-roster").await;
    w.recorder.seat_listing(vec![
        entry(w.alice.id, false, false),
        entry(w.bob.id, true, true),
    ]);

    assert_eq!(w.shown(w.alice.id).await, (json!(false), json!(false)));
    assert_eq!(w.shown(w.bob.id).await, (json!(true), json!(true)));
}

#[tokio::test]
async fn muting_has_every_viewer_read_the_roster_again() {
    let w = world("slimm-mute-nudge").await;
    w.recorder.seat_listing(vec![entry(w.bob.id, false, false)]);
    w.voice
        .record_heartbeat_at_for_test(w.bob.id, w.channel, Instant::now());
    assert_eq!(w.shown(w.bob.id).await.0, json!(false));

    w.recorder.seat_listing(vec![entry(w.bob.id, true, false)]);
    let mut rx = w.hub.subscribe();
    assert_eq!(
        w.report(&w.bob, "muted", true).await,
        StatusCode::NO_CONTENT
    );

    assert!(nudged(&mut rx, w.channel), "viewers are told to re-read");
    assert_eq!(
        w.shown(w.bob.id).await.0,
        json!(true),
        "the re-read is not served from before the mute"
    );
}

#[tokio::test]
async fn deafening_has_every_viewer_read_the_roster_again() {
    let w = world("slimm-deafen-nudge").await;
    w.recorder.seat_listing(vec![entry(w.bob.id, false, false)]);
    w.voice
        .record_heartbeat_at_for_test(w.bob.id, w.channel, Instant::now());
    assert_eq!(w.shown(w.bob.id).await.1, json!(false));

    w.recorder.seat_listing(vec![entry(w.bob.id, false, true)]);
    let mut rx = w.hub.subscribe();
    assert_eq!(
        w.report(&w.bob, "deafened", true).await,
        StatusCode::NO_CONTENT
    );

    assert!(nudged(&mut rx, w.channel));
    assert_eq!(w.shown(w.bob.id).await.1, json!(true));
    assert_eq!(w.recorder.updates.lock().unwrap().len(), 1);
}

#[tokio::test]
async fn a_report_from_someone_not_on_the_call_tells_nobody() {
    let w = world("slimm-mute-bystander").await;
    let mut rx = w.hub.subscribe();

    assert_eq!(
        w.report(&w.bob, "muted", true).await,
        StatusCode::NO_CONTENT
    );
    assert_eq!(
        w.report(&w.bob, "deafened", true).await,
        StatusCode::NO_CONTENT
    );

    assert!(!nudged(&mut rx, w.channel));
}

#[tokio::test]
async fn muting_needs_connect_and_a_voice_deployment() {
    let w = world("slimm-mute-gates").await;
    w.store
        .set_member_overwrite(w.channel, w.bob.id, Permissions::NONE, Permissions::CONNECT)
        .await
        .unwrap();
    assert_eq!(w.report(&w.bob, "muted", true).await, StatusCode::FORBIDDEN);

    let text_only = support::app::builder(w.store.clone()).router();
    let uri = format!("/channels/{}/voice/muted", w.channel);
    let (status, _) = call_as(
        &text_only,
        "PUT",
        &uri,
        &w.alice.token,
        Some(json!({ "muted": true })),
    )
    .await;
    assert_eq!(status, StatusCode::NOT_IMPLEMENTED);
}

#[tokio::test]
async fn a_report_before_the_first_heartbeat_still_drops_the_cached_roster() {
    let w = world("slimm-deafen-before-beat").await;
    w.recorder.seat_listing(vec![entry(w.bob.id, false, false)]);
    assert_eq!(w.shown(w.bob.id).await.1, json!(false));

    w.recorder.seat_listing(vec![entry(w.bob.id, false, true)]);
    assert_eq!(
        w.report(&w.bob, "deafened", true).await,
        StatusCode::NO_CONTENT
    );

    assert_eq!(
        w.shown(w.bob.id).await.1,
        json!(true),
        "a roster read from before the deafen is not served after it"
    );
}

#[tokio::test]
async fn a_first_heartbeat_nudge_is_never_answered_from_before_it() {
    let w = world("slimm-first-beat-fresh").await;
    w.recorder.seat_listing(vec![entry(w.bob.id, false, false)]);
    assert_eq!(w.shown(w.bob.id).await, (json!(false), json!(false)));

    w.recorder.seat_listing(vec![entry(w.bob.id, true, true)]);
    let mut rx = w.hub.subscribe();
    assert_eq!(w.beat(&w.bob).await, StatusCode::NO_CONTENT);

    assert!(nudged(&mut rx, w.channel), "a first heartbeat is a join");
    assert_eq!(w.shown(w.bob.id).await, (json!(true), json!(true)));
}

#[tokio::test]
async fn a_microphone_published_after_the_join_has_viewers_read_again() {
    let w = world("slimm-mic-published").await;
    w.recorder.seat_active(&[w.bob.id]);
    assert_eq!(w.shown(w.bob.id).await.0, json!(true), "no track yet");

    w.recorder.seat_listing(vec![entry(w.bob.id, false, false)]);
    let mut rx = w.hub.subscribe();
    let published = json!({
        "event": "track_published",
        "room": { "name": slimm_server::voice::room_for_channel(w.channel) },
        "participant": { "identity": w.bob.id.to_string(), "sid": format!("PA_{}", w.bob.id) },
        "track": { "sid": "TR_mic", "source": "MICROPHONE" },
    });
    assert_eq!(w.deliver(published).await, StatusCode::NO_CONTENT);

    assert!(nudged(&mut rx, w.channel), "viewers are told to re-read");
    assert_eq!(w.shown(w.bob.id).await.0, json!(false));
}

#[tokio::test]
async fn a_mute_report_that_beats_the_sfu_waits_for_it() {
    let w = world("slimm-mute-beats-sfu").await;
    w.recorder.seat_listing(vec![entry(w.bob.id, false, false)]);
    w.voice
        .record_heartbeat_at_for_test(w.bob.id, w.channel, Instant::now());
    assert_eq!(w.shown(w.bob.id).await.0, json!(false));

    let recorder = w.recorder.clone();
    let muted_at_the_sfu = entry(w.bob.id, true, false);
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(400)).await;
        recorder.seat_listing(vec![muted_at_the_sfu]);
    });
    let mut rx = w.hub.subscribe();
    assert_eq!(
        w.report(&w.bob, "muted", true).await,
        StatusCode::NO_CONTENT
    );

    assert!(nudged(&mut rx, w.channel));
    assert_eq!(
        w.shown(w.bob.id).await.0,
        json!(true),
        "the nudge waits until the SFU shows the mute"
    );
}

#[tokio::test]
async fn a_mute_the_sfu_never_shows_still_nudges_after_a_bounded_wait() {
    let w = world("slimm-mute-never-shown").await;
    w.recorder.seat_listing(vec![entry(w.bob.id, false, false)]);
    w.voice
        .record_heartbeat_at_for_test(w.bob.id, w.channel, Instant::now());
    let mut rx = w.hub.subscribe();

    let started = Instant::now();
    assert_eq!(
        w.report(&w.bob, "muted", true).await,
        StatusCode::NO_CONTENT
    );

    assert!(
        started.elapsed() < Duration::from_secs(4),
        "{:?}",
        started.elapsed()
    );
    assert!(nudged(&mut rx, w.channel));
}
