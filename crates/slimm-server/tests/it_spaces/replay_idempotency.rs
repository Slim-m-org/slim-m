// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Routes the client replays once after a dropped socket must answer a replay
//! of a change that already landed as a no-op success: no second audit row, no
//! second event, no failure shown for something that worked.

use std::future::Future;
use std::task::Poll;
use std::time::Duration;

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::hub::{Event, Hub};
use slimm_server::ids::UserId;
use slimm_server::store::{NewDebugLog, Store};
use sqlx::SqlitePool;
use tokio::sync::broadcast::Receiver;
use tower::ServiceExt;

use crate::support;
use support::app::{Account, call, register_account, request_authed};

struct World {
    store: Store,
    pool: SqlitePool,
    router: Router,
    events: Receiver<Event>,
    admin: Account,
    member: Account,
    _guard: support::TestDbGuard,
}

async fn world() -> World {
    let (store, pool, guard) = support::new_store_with_pool("slimm-replay-idempotency").await;
    let hub = Hub::new();
    let events = hub.subscribe();
    let admin = register_account(&store, "admin").await;
    let member = register_account(&store, "member").await;
    let router = support::app::builder(store.clone()).hub(hub).router();
    World {
        store,
        pool,
        router,
        events,
        admin,
        member,
        _guard: guard,
    }
}

fn unstamped(event: &Event) -> &Event {
    match event {
        Event::Stamped { event, .. } => event,
        other => other,
    }
}

impl World {
    async fn as_admin(&self, method: &str, uri: &str, body: Option<Value>) -> (StatusCode, Value) {
        call(&self.router, method, uri, Some(&self.admin.token), body).await
    }

    fn published(&mut self) -> Vec<Event> {
        std::iter::from_fn(|| self.events.try_recv().ok()).collect()
    }

    async fn audit_rows(&self, subject: UserId, action: &str) -> i64 {
        sqlx::query_scalar(
            "SELECT COUNT(*) FROM moderation_audit_log WHERE subject_id = ? AND action = ?",
        )
        .bind(subject)
        .bind(action)
        .fetch_one(&self.pool)
        .await
        .unwrap()
    }
}

#[tokio::test]
async fn replaying_a_timeout_audits_and_announces_once() {
    let mut w = world().await;
    let uri = format!("/members/{}/timeout", w.member.id);
    let body = json!({ "duration_seconds": 600, "reason": "cool off" });

    let (status, first) = w.as_admin("PUT", &uri, Some(body.clone())).await;
    assert_eq!(status, StatusCode::OK, "{first}");
    let (status, replay) = w.as_admin("PUT", &uri, Some(body)).await;
    assert_eq!(status, StatusCode::OK, "{replay}");

    assert_eq!(
        replay["until"], first["until"],
        "the deadline must not drift"
    );
    assert_eq!(w.audit_rows(w.member.id, "timeout").await, 1);
    let announced = w
        .published()
        .iter()
        .filter(|e| matches!(unstamped(e), Event::MemberTimeoutChanged { .. }))
        .count();
    assert_eq!(announced, 1);
}

#[tokio::test]
async fn a_timeout_with_another_length_still_replaces_the_deadline() {
    let w = world().await;
    let uri = format!("/members/{}/timeout", w.member.id);
    w.as_admin("PUT", &uri, Some(json!({ "duration_seconds": 600 })))
        .await;
    let (status, body) = w
        .as_admin("PUT", &uri, Some(json!({ "duration_seconds": 3600 })))
        .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(w.audit_rows(w.member.id, "timeout").await, 2);
}

#[tokio::test]
async fn replaying_a_removal_audits_and_announces_once() {
    let mut w = world().await;
    let uri = format!("/members/{}/removal", w.member.id);
    let body = json!({ "reason": "spam" });

    assert_eq!(
        w.as_admin("PUT", &uri, Some(body.clone())).await.0,
        StatusCode::NO_CONTENT
    );
    let removed_at = removal_stamp(&w).await;
    assert_eq!(
        w.as_admin("PUT", &uri, Some(body)).await.0,
        StatusCode::NO_CONTENT
    );

    assert_eq!(w.audit_rows(w.member.id, "remove").await, 1);
    assert_eq!(removal_stamp(&w).await, removed_at, "who and when stay put");
    let announced = w
        .published()
        .iter()
        .filter(|e| matches!(unstamped(e), Event::MemberRemoved { .. }))
        .count();
    assert_eq!(announced, 1);
}

async fn removal_stamp(w: &World) -> i64 {
    sqlx::query_scalar("SELECT removed_at FROM space_removals WHERE user_id = ?")
        .bind(w.member.id)
        .fetch_one(&w.pool)
        .await
        .unwrap()
}

#[tokio::test]
async fn removing_again_with_another_reason_still_records_it() {
    let w = world().await;
    let uri = format!("/members/{}/removal", w.member.id);
    w.as_admin("PUT", &uri, Some(json!({ "reason": "first" })))
        .await;
    w.as_admin("PUT", &uri, Some(json!({ "reason": "second" })))
        .await;
    assert_eq!(w.audit_rows(w.member.id, "remove").await, 2);
}

#[tokio::test]
async fn restoring_a_member_twice_succeeds_and_announces_once() {
    let mut w = world().await;
    w.store
        .remove_from_space(w.member.id, w.admin.id, None)
        .await
        .unwrap();
    w.published();
    let uri = format!("/members/{}/removal", w.member.id);
    assert_eq!(
        w.as_admin("DELETE", &uri, None).await.0,
        StatusCode::NO_CONTENT
    );
    assert_eq!(
        w.as_admin("DELETE", &uri, None).await.0,
        StatusCode::NO_CONTENT
    );
    let announced = w
        .published()
        .iter()
        .filter(|e| matches!(unstamped(e), Event::MemberRestored(_)))
        .count();
    assert_eq!(announced, 1);
    assert_eq!(w.audit_rows(w.member.id, "restore").await, 1);
}

#[tokio::test]
async fn deleting_a_role_twice_succeeds() {
    let w = world().await;
    let (_, role) = w
        .as_admin(
            "POST",
            "/roles",
            Some(json!({ "name": "mods", "permissions": 0 })),
        )
        .await;
    let uri = format!("/roles/{}", role["id"].as_str().unwrap());
    assert_eq!(
        w.as_admin("DELETE", &uri, None).await.0,
        StatusCode::NO_CONTENT
    );
    assert_eq!(
        w.as_admin("DELETE", &uri, None).await.0,
        StatusCode::NO_CONTENT
    );
}

#[tokio::test]
async fn deleting_a_theme_twice_succeeds() {
    let w = world().await;
    let file: Value =
        serde_json::from_str(include_str!("../fixtures/space_themes/forest.json")).unwrap();
    let (status, created) = w.as_admin("POST", "/space/themes", Some(file)).await;
    assert_eq!(status, StatusCode::CREATED, "{created}");
    let uri = format!("/space/themes/{}", created["id"].as_str().unwrap());
    assert_eq!(
        w.as_admin("DELETE", &uri, None).await.0,
        StatusCode::NO_CONTENT
    );
    assert_eq!(
        w.as_admin("DELETE", &uri, None).await.0,
        StatusCode::NO_CONTENT
    );
}

#[tokio::test]
async fn signing_a_device_out_twice_succeeds() {
    let w = world().await;
    let (_, devices) = call(&w.router, "GET", "/devices", Some(&w.member.token), None).await;
    let others = w
        .store
        .open_session(w.member.id, "second")
        .await
        .unwrap()
        .access_token;
    let (_, devices_now) = call(&w.router, "GET", "/devices", Some(&others), None).await;
    let known: Vec<&Value> = devices.as_array().unwrap().iter().collect();
    let extra = devices_now
        .as_array()
        .unwrap()
        .iter()
        .find(|d| !known.contains(d))
        .expect("a second device");
    let uri = format!("/devices/{}", extra["id"].as_str().unwrap());
    for _ in 0..2 {
        let (status, body) = call(&w.router, "DELETE", &uri, Some(&w.member.token), None).await;
        assert_eq!(status, StatusCode::NO_CONTENT, "{body}");
    }
}

#[tokio::test]
async fn deleting_a_debug_log_or_a_dock_source_twice_succeeds() {
    let w = world().await;
    let (log_id, _) = w
        .store
        .submit_debug_log(
            w.member.id,
            &NewDebugLog {
                note: "n",
                app_version: "1",
                platform: "linux",
                log: "line",
            },
        )
        .await
        .unwrap();
    let uri = format!("/debug-logs/{log_id}");
    assert_eq!(
        w.as_admin("DELETE", &uri, None).await.0,
        StatusCode::NO_CONTENT
    );
    assert_eq!(
        w.as_admin("DELETE", &uri, None).await.0,
        StatusCode::NO_CONTENT
    );

    let (source, _) = w
        .store
        .add_dock_source("someone/slim-addons")
        .await
        .unwrap();
    let uri = format!("/space/dock/sources/{}", source.id);
    assert_eq!(
        w.as_admin("DELETE", &uri, None).await.0,
        StatusCode::NO_CONTENT
    );
    assert_eq!(
        w.as_admin("DELETE", &uri, None).await.0,
        StatusCode::NO_CONTENT
    );
}

#[tokio::test]
async fn a_poll_replayed_after_its_close_time_returns_the_original() {
    let w = world().await;
    let channel = support::app::general_channel_id(&w.store).await;
    let uri = format!("/channels/{channel}/messages/polls");
    let close_at = chrono_now_ms() + 1_500;
    let body = json!({
        "id": uuid::Uuid::now_v7().to_string(),
        "question": "lunch?",
        "options": ["yes", "no"],
        "close_at": close_at,
    });
    let (status, first) = w.as_admin("POST", &uri, Some(body.clone())).await;
    assert_eq!(status, StatusCode::OK, "{first}");

    tokio::time::sleep(Duration::from_millis(1_700)).await;
    let (status, replay) = w.as_admin("POST", &uri, Some(body)).await;
    assert_eq!(status, StatusCode::OK, "{replay}");
    assert_eq!(replay["id"], first["id"]);
}

fn chrono_now_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
}

/// Polls the request one step at a time and drops it once `committed` holds.
async fn drop_after_commit<R, C>(request: R, mut committed: impl FnMut() -> C)
where
    R: Future,
    C: Future<Output = bool>,
{
    let mut request = Box::pin(request);
    loop {
        let finished =
            std::future::poll_fn(|cx| Poll::Ready(request.as_mut().poll(cx).is_ready())).await;
        if committed().await {
            break;
        }
        assert!(!finished, "the request finished without committing");
    }
}

async fn creation_dropped_after_commit(
    uri: &str,
    body: Value,
    stored: impl Fn(&Store) -> std::pin::Pin<Box<dyn Future<Output = bool> + Send>>,
    announced: impl Fn(&Event) -> bool,
) {
    let mut w = world().await;
    let request = w
        .router
        .clone()
        .oneshot(request_authed("POST", uri, &w.admin.token, Some(body)));
    drop_after_commit(request, || stored(&w.store)).await;

    let mut seen = 0;
    while let Ok(Ok(event)) =
        tokio::time::timeout(Duration::from_millis(500), w.events.recv()).await
    {
        seen += usize::from(announced(&event));
    }
    assert_eq!(seen, 1, "stored, but nobody else was told");
}

#[tokio::test]
async fn a_channel_create_dropped_after_it_committed_is_still_announced() {
    let id = uuid::Uuid::now_v7();
    creation_dropped_after_commit(
        "/channels",
        json!({ "id": id.to_string(), "name": "dropped" }),
        |store| {
            let store = store.clone();
            Box::pin(async move {
                store
                    .channel_including_deleted(slimm_server::ids::ChannelId(id))
                    .await
                    .unwrap()
                    .is_some()
            })
        },
        |e| matches!(unstamped(e), Event::ChannelCreated(..)),
    )
    .await;
}

#[tokio::test]
async fn a_role_create_dropped_after_it_committed_is_still_announced() {
    let id = uuid::Uuid::now_v7();
    creation_dropped_after_commit(
        "/roles",
        json!({ "id": id.to_string(), "name": "dropped", "permissions": 0 }),
        |store| {
            let store = store.clone();
            Box::pin(async move {
                store
                    .role(slimm_server::ids::RoleId(id))
                    .await
                    .unwrap()
                    .is_some()
            })
        },
        |e| matches!(unstamped(e), Event::RoleChanged { .. }),
    )
    .await;
}
