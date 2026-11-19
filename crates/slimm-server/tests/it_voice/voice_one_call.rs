// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A member is on one call: joining a second room ends their older call in the first.
//! The SFU replaces a connection only within one room, so the proof is a `RemoveParticipant` for the other.

use std::time::Duration;

use axum::Router;
use axum::http::StatusCode;
use serde_json::json;
use slimm_server::http::{self, AppState};
use slimm_server::ids::{ChannelId, UserId};
use slimm_server::voice::VoiceService;
use tower::ServiceExt;

use crate::support;
use support::app::{Account, call_as, register_account};
use support::fake_sfu::{RecordingRoomService, spawn_sfu};
use support::livekit_webhook::webhook_request;
use support::wait::{holds_within, wait_until};

const SFU_KEY: &str = "key";
const SFU_SECRET: &str = "a-secret-at-least-32-chars-long!";
const EARLIER: i64 = 1_700_000_000_000;
const LATER: i64 = EARLIER + 60_000;

struct World {
    recorder: RecordingRoomService,
    router: Router,
    state: AppState,
    admin: Account,
    lounge: String,
    den: String,
    _db: support::TestDbGuard,
}

impl World {
    async fn start() -> Self {
        let recorder = RecordingRoomService::default();
        let url = spawn_sfu(recorder.clone()).await;
        let (store, db) = support::new_store("slimm-voice-one-call").await;
        let admin = register_account(&store, "admin").await;
        let voice = VoiceService::for_test(&url, SFU_KEY, SFU_SECRET);
        let state = support::app::builder(store).voice(voice).build();
        let router = http::router(state.clone());
        let mut world = Self {
            recorder,
            router,
            state,
            admin,
            lounge: String::new(),
            den: String::new(),
            _db: db,
        };
        world.lounge = world.voice_channel("lounge").await;
        world.den = world.voice_channel("den").await;
        world
    }

    async fn voice_channel(&self, name: &str) -> String {
        let body = json!({ "name": name, "kind": "voice" });
        let (status, body) = call_as(
            &self.router,
            "POST",
            "/channels",
            &self.admin.token,
            Some(body),
        )
        .await;
        assert!(status.is_success(), "create channel: {status} {body}");
        body["id"].as_str().unwrap().to_owned()
    }

    async fn bot(&self) -> (UserId, String) {
        let body = json!({ "username": "jukebox" });
        let (status, body) =
            call_as(&self.router, "POST", "/bots", &self.admin.token, Some(body)).await;
        assert_eq!(status, StatusCode::CREATED, "{body}");
        let id = body["bot"]["user_id"].as_str().unwrap().parse().unwrap();
        (UserId(id), body["token"].as_str().unwrap().to_owned())
    }

    /// On the call as the server knows it: a heartbeat on record and a seat in the SFU's room.
    async fn on_call(&self, channel: &str, user: UserId, token: &str, joined_at_ms: i64) {
        let uri = format!("/channels/{channel}/voice/heartbeat");
        let (status, _) = call_as(&self.router, "POST", &uri, token, None).await;
        assert_eq!(status, StatusCode::NO_CONTENT);
        self.recorder
            .seat_joined_in(&format!("channel-{channel}"), &[(user, joined_at_ms)]);
    }

    async fn sfu_reports_join(&self, channel: &str, user: UserId, joined_at_ms: i64) {
        let body = json!({
            "event": "participant_joined",
            "room": { "name": format!("channel-{channel}") },
            "participant": {
                "identity": user.to_string(),
                "sid": format!("PA_{channel}"),
                "joined_at_ms": joined_at_ms,
            },
        });
        let request = webhook_request(body, SFU_KEY, SFU_SECRET);
        let response = self.router.clone().oneshot(request).await.unwrap();
        assert_eq!(response.status(), StatusCode::NO_CONTENT);
    }

    fn removed(&self, channel: &str, user: UserId) -> bool {
        let room = format!("channel-{channel}");
        self.recorder
            .removed
            .lock()
            .unwrap()
            .iter()
            .any(|c| c["room"] == room.as_str() && c["identity"] == user.to_string().as_str())
    }

    fn in_call(&self, channel: &str, user: UserId) -> bool {
        self.state
            .voice
            .has_heartbeat(user, ChannelId(channel.parse().unwrap()))
    }

    async fn nobody_removed(&self, channel: &str, user: UserId) -> bool {
        !holds_within(Duration::from_millis(300), || self.removed(channel, user)).await
    }
}

/// A second device told "joining here moves your call" joins another channel: the first leaves.
#[tokio::test]
async fn joining_another_room_ends_the_older_call() {
    let world = World::start().await;
    let (me, token) = (world.admin.id, world.admin.token.clone());
    world.on_call(&world.lounge, me, &token, EARLIER).await;

    world.sfu_reports_join(&world.den, me, LATER).await;

    wait_until("the older call is ended at the sfu", || {
        world.removed(&world.lounge, me)
    })
    .await;
    assert!(!world.in_call(&world.lounge, me));
    assert!(
        !world.removed(&world.den, me),
        "the call just joined was ended"
    );
}

/// A join reported late, after the member is already back in the first room, ends nothing.
#[tokio::test]
async fn a_call_joined_after_the_reported_one_is_kept() {
    let world = World::start().await;
    let (me, token) = (world.admin.id, world.admin.token.clone());
    world.on_call(&world.lounge, me, &token, LATER).await;

    world.sfu_reports_join(&world.den, me, EARLIER).await;

    assert!(world.nobody_removed(&world.lounge, me).await);
    assert!(world.in_call(&world.lounge, me));
}

/// A heartbeat can outlive the connection it was for; without a seat there is nothing to end.
#[tokio::test]
async fn a_room_the_member_already_left_is_not_asked_to_remove_them() {
    let world = World::start().await;
    let (me, token) = (world.admin.id, world.admin.token.clone());
    world.on_call(&world.lounge, me, &token, EARLIER).await;
    world
        .recorder
        .seat_joined_in(&format!("channel-{}", world.lounge), &[]);

    world.sfu_reports_join(&world.den, me, LATER).await;

    assert!(world.nobody_removed(&world.lounge, me).await);
}

/// A bot is a program, and one may serve several calls at once.
#[tokio::test]
async fn a_bot_stays_on_every_call_it_joined() {
    let world = World::start().await;
    let (bot, token) = world.bot().await;
    world.on_call(&world.lounge, bot, &token, EARLIER).await;

    world.sfu_reports_join(&world.den, bot, LATER).await;

    assert!(world.nobody_removed(&world.lounge, bot).await);
    assert!(world.in_call(&world.lounge, bot));
}
