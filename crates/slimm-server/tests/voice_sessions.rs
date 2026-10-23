// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Voice sessions (decision 0091): one row per member per call, opened and
//! closed by signed LiveKit webhooks, and capped by the other ways a call ends.

use std::time::{Duration, Instant};

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::hub::Hub;
use slimm_server::ids::{ChannelId, UserId};
use slimm_server::store::{SessionScope, Store};
use slimm_server::voice::VoiceService;
use tower::ServiceExt;

mod support;

use support::livekit_webhook::webhook_request;

const API_KEY: &str = "APItestkey";
const API_SECRET: &str = "a-test-secret-of-at-least-32-characters";

struct World {
    app: Router,
    store: Store,
    pool: sqlx::SqlitePool,
    voice: VoiceService,
    channel: ChannelId,
    user: UserId,
    other: UserId,
    _guard: support::TestDbGuard,
}

async fn world(prefix: &str) -> World {
    let (store, pool, guard) = support::new_store_with_pool(prefix).await;
    // An address nothing listens on: removal calls fail quietly.
    let voice = VoiceService::for_test("http://127.0.0.1:1", API_KEY, API_SECRET);
    let app = support::app::builder(store.clone())
        .voice(voice.clone())
        .router();
    let user = store.create_user("nia", "Nia").await.unwrap().id;
    store.bootstrap_deployment(user).await.unwrap();
    let other = store.create_user("kiki", "Kiki").await.unwrap().id;
    let channel = store.create_channel("voice", "voice").await.unwrap().id;
    World {
        app,
        store,
        pool,
        voice,
        channel,
        user,
        other,
        _guard: guard,
    }
}

impl World {
    async fn deliver(&self, event: &str, who: Option<(UserId, &str)>) -> StatusCode {
        let mut body =
            json!({ "event": event, "room": { "name": format!("channel-{}", self.channel) } });
        if let Some((user, sid)) = who {
            body["participant"] = json!({ "identity": user.to_string(), "sid": sid });
        }
        self.app
            .clone()
            .oneshot(webhook_request(body, API_KEY, API_SECRET))
            .await
            .unwrap()
            .status()
    }

    async fn sessions(&self) -> Vec<Value> {
        let rows = sqlx::query_as::<_, (i64, Vec<u8>, String, i64, Option<i64>, i64)>(
            "SELECT id, user_id, sid, joined_at, left_at, alone_ms FROM voice_sessions ORDER BY id",
        )
        .fetch_all(&self.pool)
        .await
        .unwrap();
        rows.into_iter()
            .map(|(id, _, sid, joined, left, alone)| {
                json!({ "id": id, "sid": sid, "joined_at": joined, "left_at": left, "alone_ms": alone })
            })
            .collect()
    }
}

#[tokio::test]
async fn a_join_and_a_leave_make_one_closed_session() {
    let w = world("slimm-vs-one").await;
    assert_eq!(
        w.deliver("participant_joined", Some((w.user, "PA_1")))
            .await,
        StatusCode::NO_CONTENT
    );
    let open = w.sessions().await;
    assert_eq!(open.len(), 1);
    assert!(open[0]["left_at"].is_null());

    w.deliver("participant_left", Some((w.user, "PA_1"))).await;
    let closed = w.sessions().await;
    assert_eq!(closed.len(), 1);
    assert_eq!(closed[0]["sid"], "PA_1");
    assert!(closed[0]["left_at"].as_i64().unwrap() >= closed[0]["joined_at"].as_i64().unwrap());
}

#[tokio::test]
async fn a_duplicate_join_for_an_open_sid_adds_no_row() {
    let w = world("slimm-vs-dup").await;
    w.deliver("participant_joined", Some((w.user, "PA_1")))
        .await;
    w.deliver("participant_joined", Some((w.user, "PA_1")))
        .await;
    assert_eq!(w.sessions().await.len(), 1);
}

#[tokio::test]
async fn a_leave_for_an_unknown_sid_is_ignored() {
    let w = world("slimm-vs-unknown").await;
    w.deliver("participant_joined", Some((w.user, "PA_1")))
        .await;
    let status = w
        .deliver("participant_left", Some((w.user, "PA_other")))
        .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let rows = w.sessions().await;
    assert_eq!(rows.len(), 1);
    assert!(
        rows[0]["left_at"].is_null(),
        "another sid's leave must not close it"
    );

    let empty = world("slimm-vs-unknown2").await;
    empty
        .deliver("participant_left", Some((empty.user, "PA_1")))
        .await;
    assert!(empty.sessions().await.is_empty());
}

#[tokio::test]
async fn a_finished_room_closes_everyone_in_it() {
    let w = world("slimm-vs-finished").await;
    w.deliver("participant_joined", Some((w.user, "PA_1")))
        .await;
    w.deliver("participant_joined", Some((w.other, "PA_2")))
        .await;
    w.deliver("room_finished", None).await;
    let rows = w.sessions().await;
    assert_eq!(rows.len(), 2);
    assert!(rows.iter().all(|r| !r["left_at"].is_null()));
}

#[tokio::test]
async fn a_stale_heartbeat_sweep_closes_that_members_session() {
    let w = world("slimm-vs-stale").await;
    w.deliver("participant_joined", Some((w.user, "PA_1")))
        .await;
    w.deliver("participant_joined", Some((w.other, "PA_2")))
        .await;
    let start = Instant::now();
    w.voice
        .record_heartbeat_at_for_test(w.user, w.channel, start);
    let stale = slimm_server::sweep_stale_voice_calls_at(
        &w.voice,
        &Hub::new(),
        start + Duration::from_secs(41),
    )
    .await;
    slimm_server::close_stale_sessions(&w.store, &stale).await;

    let rows = w.sessions().await;
    assert!(
        !rows[0]["left_at"].is_null(),
        "the stale member's session closed"
    );
    assert!(
        rows[1]["left_at"].is_null(),
        "the other member's stays open"
    );
}

#[tokio::test]
async fn startup_closes_every_session_left_open() {
    let w = world("slimm-vs-startup").await;
    w.deliver("participant_joined", Some((w.user, "PA_1")))
        .await;
    w.deliver("participant_joined", Some((w.other, "PA_2")))
        .await;
    slimm_server::reconcile_on_startup(&w.store).await;
    assert!(w.sessions().await.iter().all(|r| !r["left_at"].is_null()));
}

#[tokio::test]
async fn a_missed_leave_caps_the_session_at_the_next_join() {
    let w = world("slimm-vs-missed").await;
    let (s, c, u) = (&w.store, w.channel, w.user);
    assert!(s.open_voice_session(c, u, "PA_old", 1_000).await.unwrap());
    assert!(s.open_voice_session(c, u, "PA_new", 5_000).await.unwrap());
    let rows = w.sessions().await;
    assert_eq!(
        rows[0]["left_at"], 5_000,
        "the old session ends where the new one began"
    );
    assert!(rows[1]["left_at"].is_null());
}

#[tokio::test]
async fn alone_time_is_only_the_stretch_nobody_else_was_there() {
    let w = world("slimm-vs-alone").await;
    let (s, c) = (&w.store, w.channel);
    s.open_voice_session(c, w.user, "PA_1", 0).await.unwrap();
    s.open_voice_session(c, w.other, "PA_2", 1_000)
        .await
        .unwrap();
    let first = s
        .close_voice_sessions(SessionScope::Sid(w.user, "PA_1"), 3_000)
        .await
        .unwrap();
    let second = s
        .close_voice_sessions(SessionScope::Sid(w.other, "PA_2"), 4_000)
        .await
        .unwrap();
    assert_eq!(first[0].alone_ms, 1_000, "alone before the second joined");
    assert_eq!(second[0].alone_ms, 1_000, "alone after the first left");
}

#[tokio::test]
async fn closed_sessions_past_ninety_days_are_pruned() {
    let w = world("slimm-vs-prune").await;
    let (s, c) = (&w.store, w.channel);
    let day = 24 * 60 * 60 * 1000;
    let now = chrono_now_ms();
    s.open_voice_session(c, w.user, "PA_old", now - 100 * day)
        .await
        .unwrap();
    s.close_voice_sessions(SessionScope::Everyone, now - 99 * day)
        .await
        .unwrap();
    s.open_voice_session(c, w.user, "PA_recent", now - 2 * day)
        .await
        .unwrap();
    s.close_voice_sessions(SessionScope::Everyone, now - day)
        .await
        .unwrap();
    s.open_voice_session(c, w.other, "PA_open", now - 100 * day)
        .await
        .unwrap();

    assert_eq!(s.sweep_voice_sessions().await.unwrap(), 1);
    let sids: Vec<_> = w
        .sessions()
        .await
        .iter()
        .map(|r| r["sid"].clone())
        .collect();
    assert_eq!(
        sids,
        vec!["PA_recent", "PA_open"],
        "open sessions are never pruned"
    );
}

#[tokio::test]
async fn deleting_an_account_removes_its_sessions() {
    let w = world("slimm-vs-delete").await;
    let (s, c) = (&w.store, w.channel);
    s.open_voice_session(c, w.user, "PA_1", 0).await.unwrap();
    s.open_voice_session(c, w.other, "PA_2", 0).await.unwrap();
    s.delete_account(w.other).await.unwrap();
    let rows = w.sessions().await;
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0]["sid"], "PA_1");
}

fn chrono_now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
}
