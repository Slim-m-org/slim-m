// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A member is on one call: joining a second room ends their older call in the first.
//! The SFU replaces a connection only within one room, so the proof is a `RemoveParticipant` for the other.
//! The call that wins is the one the member last asked a token for, never one a device walked back into.

use std::time::Duration;

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
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

    /// Asks for a join token, as a person's own join does, or a client's own comeback when `automatic`.
    async fn asks_token(&self, channel: &str, token: &str, automatic: bool) -> (StatusCode, Value) {
        let query = if automatic { "?automatic=true" } else { "" };
        let uri = format!("/channels/{channel}/voice/token{query}");
        call_as(&self.router, "POST", &uri, token, None).await
    }

    /// A join the member asked for: a token, then the heartbeat and the seat of [`Self::on_call`].
    async fn joins(&self, channel: &str, user: UserId, token: &str, joined_at_ms: i64) {
        let (status, body) = self.asks_token(channel, token, false).await;
        assert_eq!(status, StatusCode::OK, "{body}");
        self.on_call(channel, user, token, joined_at_ms).await;
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
    world.joins(&world.lounge, me, &token, EARLIER).await;
    world.joins(&world.den, me, &token, LATER).await;

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

/// A device that lost its network walks back into its room on a token the SFU renewed, after its
/// person joined another call: the call asked for last is the one kept.
#[tokio::test]
async fn a_reconnect_into_the_room_left_behind_gives_way() {
    let world = World::start().await;
    let (me, token) = (world.admin.id, world.admin.token.clone());
    world.joins(&world.lounge, me, &token, EARLIER).await;
    world.joins(&world.den, me, &token, LATER).await;
    let reconnected = LATER + 60_000;
    world
        .recorder
        .seat_joined_in(&format!("channel-{}", world.lounge), &[(me, reconnected)]);

    world.sfu_reports_join(&world.lounge, me, reconnected).await;

    wait_until("the connection that came back is removed", || {
        world.removed(&world.lounge, me)
    })
    .await;
    assert!(
        !world.removed(&world.den, me),
        "the call the member is on was ended by a device coming back"
    );
    assert!(world.in_call(&world.den, me));
}

/// A restart forgets which call was asked for; with nothing to choose by, neither call is ended.
#[tokio::test]
async fn a_join_with_no_token_on_record_ends_nothing() {
    let world = World::start().await;
    let (me, token) = (world.admin.id, world.admin.token.clone());
    world.on_call(&world.lounge, me, &token, EARLIER).await;

    world.sfu_reports_join(&world.den, me, LATER).await;

    assert!(world.nobody_removed(&world.lounge, me).await);
    assert!(!world.removed(&world.den, me));
}

/// A client rejoining by itself asks first, and is told the member has moved on.
#[tokio::test]
async fn a_comeback_is_refused_while_the_member_is_on_another_call() {
    let world = World::start().await;
    let (me, token) = (world.admin.id, world.admin.token.clone());
    world.joins(&world.den, me, &token, EARLIER).await;

    let (status, body) = world.asks_token(&world.lounge, &token, true).await;

    assert_eq!(status, StatusCode::CONFLICT, "{body}");
    assert_eq!(body["code"], "on_call_elsewhere");
    let (status, body) = world.asks_token(&world.lounge, &token, false).await;
    assert_eq!(
        status,
        StatusCode::OK,
        "a person's own join moves the call: {body}"
    );
}

/// The same refusal when another device took the very call the client is coming back to.
#[tokio::test]
async fn a_comeback_is_refused_when_another_device_holds_the_call() {
    let world = World::start().await;
    let (me, token) = (world.admin.id, world.admin.token.clone());
    let room = format!("channel-{}", world.lounge);
    let seat = |device: Option<&str>| {
        let mut seated = json!({ "identity": me.to_string(), "sid": "PA_1" });
        if let Some(device) = device {
            seated["attributes"] = json!({ "slimm.device": device });
        }
        world.recorder.seat_in_listing(&room, vec![seated]);
    };

    seat(Some("another-device"));
    let (status, body) = world.asks_token(&world.lounge, &token, true).await;
    assert_eq!(status, StatusCode::CONFLICT, "{body}");
    assert_eq!(body["code"], "on_call_elsewhere");

    seat(None);
    let (status, body) = world.asks_token(&world.lounge, &token, true).await;
    assert_eq!(
        status,
        StatusCode::OK,
        "a leftover connection that names no device is not another device: {body}"
    );
}

/// With no call anywhere else, a comeback is an ordinary join.
#[tokio::test]
async fn a_comeback_to_the_only_call_is_granted() {
    let world = World::start().await;
    let (me, token) = (world.admin.id, world.admin.token.clone());
    world.joins(&world.lounge, me, &token, EARLIER).await;

    let (status, body) = world.asks_token(&world.lounge, &token, true).await;

    assert_eq!(status, StatusCode::OK, "{body}");
}
