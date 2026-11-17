// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Stamps on a shared screen (decision 0121): [`placing`] covers the route's checks and
//! the relay, [`delivery`] who hears a stamp, [`pictures`] the 24-hour fetch grant, the
//! sweep and the sharer's report, [`received`] the sharer's list of who stamped pictures
//! on their screen, and [`report_scope`] who sees a report whose pictures came from
//! several channels.

mod delivery;
mod pictures;
mod placing;
mod received;
mod report_scope;

use std::time::Instant;

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::http::{self, AppState};
use slimm_server::ids::{ChannelId, UserId};
use slimm_server::store::Store;
use slimm_server::voice::VoiceService;
use sqlx::SqlitePool;
use tower::ServiceExt;

use crate::support;
use support::app::{Account, json_body_or_null, register_account};
use support::fake_sfu::{RecordingRoomService, spawn_sfu};
use support::ws::{Client, connect, read_frame_of_type, serve};

pub(super) const KIND: &str = "canvas.screen_annotation.updated";

/// A party emoji, escaped so no emoji sits in source.
pub(super) const PARTY: &str = "\u{1F389}";

pub(super) const DAY_MS: i64 = 24 * 60 * 60 * 1000;

/// A call in "lounge": `sharer` shares a screen, `viewer` and `carol` watch, `dave` is outside.
pub(super) struct Rig {
    pub store: Store,
    pub pool: SqlitePool,
    pub state: AppState,
    pub router: Router,
    pub room: RecordingRoomService,
    pub channel: String,
    pub channel_id: ChannelId,
    pub admin: Account,
    pub sharer: Account,
    pub viewer: Account,
    pub carol: Account,
    pub dave: Account,
    _db: support::TestDbGuard,
}

pub(super) async fn rig() -> Rig {
    let room = RecordingRoomService::default();
    let sfu = spawn_sfu(room.clone()).await;
    let (store, pool, db) = support::new_store_with_pool("slimm-screen-stamps").await;
    let admin = register_account(&store, "admin").await;
    let sharer = register_account(&store, "sharer").await;
    let viewer = register_account(&store, "viewer").await;
    let carol = register_account(&store, "carol").await;
    let dave = register_account(&store, "dave").await;
    let channel = store.create_channel("lounge", "voice").await.unwrap();
    let voice = VoiceService::for_test(&sfu, "key", "a-secret-at-least-32-chars-long!");
    let state = support::app::builder(store.clone()).voice(voice).build();
    room.seat_sharing(&[sharer.id, viewer.id, carol.id], &[sharer.id]);
    Rig {
        store,
        pool,
        router: http::router(state.clone()),
        state,
        room,
        channel: channel.id.to_string(),
        channel_id: channel.id,
        admin,
        sharer,
        viewer,
        carol,
        dave,
        _db: db,
    }
}

impl Rig {
    /// What the sharer's client says in its consent heartbeat, recorded as the socket would.
    pub fn consent(&self, allowed: bool, stamps: bool) {
        self.state.hub.screen_consent().record(
            self.channel_id,
            self.sharer.id,
            (allowed, stamps),
            Instant::now(),
        );
    }

    /// Who is in the call now, dropping the cached roster so the next check sees it.
    pub fn seat(&self, users: &[UserId], sharers: &[UserId]) {
        self.room.seat_sharing(users, sharers);
        self.state.voice.roster_cache().invalidate(self.channel_id);
    }

    pub async fn send(
        &self,
        method: &str,
        uri: &str,
        token: &str,
        body: Option<Value>,
    ) -> (StatusCode, Value) {
        support::app::call_as(&self.router, method, uri, token, body).await
    }

    pub async fn stamp(&self, token: &str, body: Value) -> (StatusCode, Value) {
        let uri = format!("/channels/{}/voice/screen-stamps", self.channel);
        self.send("POST", &uri, token, Some(body)).await
    }

    /// An emoji stamp from anyone onto the sharer's screen, with a fresh id.
    pub fn emoji(&self, emoji: &str) -> Value {
        json!({
            "id": uuid::Uuid::now_v7().to_string(),
            "target_user_id": self.sharer.id.to_string(),
            "x": 0.42, "y": 0.31, "size": 0.12, "emoji": emoji,
        })
    }

    /// A picture stamp onto the sharer's screen, with a fresh id.
    pub fn picture(&self, attachment_id: &str) -> Value {
        json!({
            "id": uuid::Uuid::now_v7().to_string(),
            "target_user_id": self.sharer.id.to_string(),
            "x": 0.5, "y": 0.5, "size": 0.2, "attachment_id": attachment_id,
        })
    }

    /// Uploads `bytes` as `token` and returns the attachment id.
    pub async fn upload(&self, token: &str, filename: &str, bytes: Vec<u8>) -> String {
        let request = Request::builder()
            .method("POST")
            .uri(format!("/attachments?filename={filename}"))
            .header("authorization", format!("Bearer {token}"))
            .body(Body::from(bytes))
            .unwrap();
        let response = self.router.clone().oneshot(request).await.unwrap();
        let status = response.status();
        let body = json_body_or_null(response).await;
        assert_eq!(status, StatusCode::CREATED, "{body}");
        body["id"].as_str().unwrap().to_owned()
    }

    /// A small PNG uploaded by the viewer, distinct per `filler`.
    pub async fn viewer_png(&self, filler: &[u8]) -> String {
        let bytes = support::images::png(16, 16, filler);
        self.upload(&self.viewer.token, "pixel.png", bytes).await
    }

    pub async fn fetch_status(&self, token: &str, attachment_id: &str) -> StatusCode {
        let uri = format!("/attachments/{attachment_id}");
        self.send("GET", &uri, token, None).await.0
    }

    pub async fn socket(&self, account: &Account) -> Client {
        let addr = serve(self.state.clone()).await;
        let ctx = self
            .store
            .authenticate(&account.token)
            .await
            .unwrap()
            .unwrap();
        let (ticket, _) = self.store.mint_ws_ticket(&ctx).await.unwrap();
        connect(addr, &ticket).await
    }

    /// Ages every stamp and every attachment by a day and a minute.
    pub async fn age_a_day(&self) {
        for table in ["screen_stamps", "attachments"] {
            sqlx::query(&format!("UPDATE {table} SET created_at = created_at - ?"))
                .bind(DAY_MS + 60_000)
                .execute(&self.pool)
                .await
                .unwrap();
        }
    }

    pub async fn count(&self, sql: &str) -> i64 {
        sqlx::query_scalar(sql).fetch_one(&self.pool).await.unwrap()
    }
}

/// The next relayed stamp on `ws`, skipping every other screen mark.
pub(super) async fn read_stamp(ws: &mut Client) -> Value {
    loop {
        let frame = read_frame_of_type(ws, KIND).await;
        if frame["kind"] == "stamp" {
            return frame;
        }
    }
}
