// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A lock or a limit holds against a join that did not come from a token this server just minted
//! (a token the SFU renewed), and a heartbeat meets the gates the token does.

use std::time::Duration;

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

struct LockedRoom {
    recorder: RecordingRoomService,
    router: axum::Router,
    state: AppState,
    host: Account,
    guest: Account,
    room: String,
    _db: support::TestDbGuard,
}

impl LockedRoom {
    async fn start(lock: bool) -> Self {
        let recorder = RecordingRoomService::default();
        let url = spawn_sfu(recorder.clone()).await;
        let (store, db) = support::new_store("slimm-voice-join-gates").await;
        let admin = register_account(&store, "admin").await;
        let host = register_account(&store, "host").await;
        let guest = register_account(&store, "guest").await;
        let voice = VoiceService::for_test(&url, SFU_KEY, SFU_SECRET);
        let state = support::app::builder(store).voice(voice).build();
        let router = http::router(state.clone());
        let body = json!({ "name": "lobby", "kind": "voice", "creates_rooms": true });
        let (_, lobby) = call_as(&router, "POST", "/channels", &admin.token, Some(body)).await;
        let uri = format!("/channels/{}/voice/room", lobby["id"].as_str().unwrap());
        let (status, room) = call_as(&router, "POST", &uri, &host.token, None).await;
        assert_eq!(status, StatusCode::OK, "{room}");
        let this = Self {
            recorder,
            router,
            state,
            host,
            guest,
            room: room["id"].as_str().unwrap().to_owned(),
            _db: db,
        };
        if lock {
            this.lock().await;
        }
        this
    }

    async fn lock(&self) {
        let uri = format!("/channels/{}/room", self.room);
        let (status, body) = self
            .call("PATCH", &uri, &self.host, Some(json!({ "locked": true })))
            .await;
        assert_eq!(status, StatusCode::OK, "{body}");
    }

    async fn call(
        &self,
        method: &str,
        uri: &str,
        who: &Account,
        body: Option<Value>,
    ) -> (StatusCode, Value) {
        call_as(&self.router, method, uri, &who.token, body).await
    }

    async fn mint(&self, who: &Account) -> StatusCode {
        let uri = format!("/channels/{}/voice/token", self.room);
        self.call("POST", &uri, who, None).await.0
    }

    async fn heartbeat(&self, who: &Account) -> StatusCode {
        let uri = format!("/channels/{}/voice/heartbeat", self.room);
        self.call("POST", &uri, who, None).await.0
    }

    async fn sfu_reports_join(&self, user: UserId) {
        let body = json!({
            "event": "participant_joined",
            "room": { "name": format!("channel-{}", self.room) },
            "participant": { "identity": user.to_string(), "sid": "PA_join" },
        });
        let request = webhook_request(body, SFU_KEY, SFU_SECRET);
        let response = self.router.clone().oneshot(request).await.unwrap();
        assert_eq!(response.status(), StatusCode::NO_CONTENT);
    }

    fn removed(&self, user: UserId) -> bool {
        self.recorder
            .removed
            .lock()
            .unwrap()
            .iter()
            .any(|c| c["identity"] == user.to_string().as_str())
    }

    fn has_heartbeat(&self, user: UserId) -> bool {
        let channel = ChannelId(self.room.parse().unwrap());
        self.state.voice.has_heartbeat(user, channel)
    }
}

#[tokio::test]
async fn a_join_with_no_token_minted_for_it_is_turned_away_from_a_locked_room() {
    let room = LockedRoom::start(true).await;

    room.sfu_reports_join(room.guest.id).await;

    wait_until("the guest is removed", || room.removed(room.guest.id)).await;
}

#[tokio::test]
async fn a_join_on_a_token_minted_just_before_the_lock_stays() {
    let room = LockedRoom::start(false).await;
    assert_eq!(room.mint(&room.guest).await, StatusCode::OK);
    room.lock().await;

    room.sfu_reports_join(room.guest.id).await;

    let removed = holds_within(Duration::from_millis(400), || room.removed(room.guest.id)).await;
    assert!(!removed, "a join on a freshly minted token was removed");
}

#[tokio::test]
async fn the_owner_of_a_locked_room_joins_without_a_token() {
    let room = LockedRoom::start(true).await;

    room.sfu_reports_join(room.host.id).await;

    let removed = holds_within(Duration::from_millis(400), || room.removed(room.host.id)).await;
    assert!(
        !removed,
        "the room's owner was turned away from their own room"
    );
}

#[tokio::test]
async fn a_heartbeat_into_a_locked_room_is_refused_like_the_token() {
    let room = LockedRoom::start(true).await;
    assert_eq!(room.mint(&room.guest).await, StatusCode::CONFLICT);

    assert_eq!(room.heartbeat(&room.guest).await, StatusCode::CONFLICT);

    assert!(!room.has_heartbeat(room.guest.id));
}

#[tokio::test]
async fn a_heartbeat_from_someone_the_sfu_lists_in_a_locked_room_is_kept() {
    let room = LockedRoom::start(true).await;
    room.recorder
        .seat_in(&format!("channel-{}", room.room), &[room.guest.id]);

    assert_eq!(room.heartbeat(&room.guest).await, StatusCode::NO_CONTENT);

    assert!(room.has_heartbeat(room.guest.id));
}
