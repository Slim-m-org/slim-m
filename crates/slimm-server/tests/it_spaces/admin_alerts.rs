// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Operator alerts: the list route, the per-admin mute, the live notice that reaches only an
//! unmuted `MANAGE_SERVER` holder, the monitor opening and closing alerts, and the backup
//! status on `GET /space/storage`. Pushes are in `tests/it_notify/push_endpoints/admin_alerts.rs`.

use std::time::Duration;

use axum::http::StatusCode;
use futures_util::StreamExt;
use serde_json::{Value, json};
use slimm_server::admin_alerts::{AlertKind, Monitor, MonitorSettings, Notifier};
use slimm_server::http::{self, BackupStatusDir};
use slimm_server::permissions::Permissions;
use slimm_server::store::{Raised, Store};
use tokio_tungstenite::tungstenite::Message as WsMessage;
use tower::ServiceExt;

use crate::support;
use support::app::{call, request_json};
use support::ws::{Client, connect, serve, user_ticket};

const HOUR_MS: i64 = 3_600_000;

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
}

async fn seeded(prefix: &str) -> (Store, support::TestDbGuard) {
    support::new_store(prefix).await
}

async fn admin_and_member(store: &Store) -> (String, String) {
    let admin = support::app::register_account(store, "root").await;
    let member = support::app::register_account(store, "nia").await;
    (admin.token, member.token)
}

async fn list(router: &axum::Router, token: &str) -> Value {
    let (status, body) = call(router, "GET", "/space/alerts", Some(token), None).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    body
}

#[tokio::test]
async fn the_list_needs_manage_server() {
    let (store, _guard) = seeded("slimm-alerts-forbidden").await;
    let (admin, member) = admin_and_member(&store).await;
    let router = support::app::app(store);

    let (denied, _) = call(&router, "GET", "/space/alerts", Some(&member), None).await;
    let (denied_put, _) = call(
        &router,
        "PUT",
        "/space/alerts/mute",
        Some(&member),
        Some(json!({ "muted": true })),
    )
    .await;

    assert_eq!(denied, StatusCode::FORBIDDEN);
    assert_eq!(denied_put, StatusCode::FORBIDDEN);
    assert_eq!(list(&router, &admin).await["alerts"], json!([]));
}

#[tokio::test]
async fn raising_twice_is_one_alert_and_resolving_keeps_it_visible_as_recovered() {
    let (store, _guard) = seeded("slimm-alerts-dedupe").await;
    let (admin, _member) = admin_and_member(&store).await;
    let state = support::app::state(store.clone());
    let router = http::router(state.clone());
    let notifier = Notifier::from_state(&state);

    notifier
        .raise(AlertKind::DiskLow, "", "Only 90 MB are free.")
        .await;
    notifier
        .raise(AlertKind::DiskLow, "", "Only 80 MB are free.")
        .await;

    let body = list(&router, &admin).await;
    let alerts = body["alerts"].as_array().unwrap();
    assert_eq!(alerts.len(), 1, "{body}");
    assert_eq!(alerts[0]["kind"], "disk_low");
    assert_eq!(alerts[0]["resolved_at"], Value::Null);

    notifier.resolve(AlertKind::DiskLow, "").await;

    let body = list(&router, &admin).await;
    assert!(body["alerts"][0]["resolved_at"].is_i64(), "{body}");
}

#[tokio::test]
async fn a_recovered_alert_that_reopens_is_open_again() {
    let (store, _guard) = seeded("slimm-alerts-reopen").await;
    assert_eq!(
        store
            .raise_admin_alert("backup", "", "failed", 10)
            .await
            .unwrap(),
        Raised::Opened
    );
    assert_eq!(
        store
            .raise_admin_alert("backup", "", "failed", 20)
            .await
            .unwrap(),
        Raised::AlreadyOpen
    );
    store.resolve_admin_alert("backup", "", 30).await.unwrap();
    assert_eq!(
        store
            .raise_admin_alert("backup", "", "failed", 40)
            .await
            .unwrap(),
        Raised::Opened
    );
    let alerts = store.list_admin_alerts(0).await.unwrap();
    assert_eq!((alerts[0].raised_at, alerts[0].resolved_at), (40, None));
}

#[tokio::test]
async fn the_push_window_is_per_kind_and_opens_again_after_six_hours() {
    let (store, _guard) = seeded("slimm-alerts-window").await;
    let window = 6 * HOUR_MS;
    store
        .raise_admin_alert("module_breaker", "a", "x", 0)
        .await
        .unwrap();
    store
        .raise_admin_alert("module_breaker", "b", "x", 0)
        .await
        .unwrap();
    store.raise_admin_alert("backup", "", "x", 0).await.unwrap();

    assert!(
        store
            .claim_admin_alert_push("module_breaker", "a", 1_000, window)
            .await
            .unwrap()
    );
    assert!(
        !store
            .claim_admin_alert_push("module_breaker", "b", 2_000, window)
            .await
            .unwrap()
    );
    assert!(
        store
            .claim_admin_alert_push("backup", "", 2_000, window)
            .await
            .unwrap()
    );
    assert!(
        !store
            .claim_admin_alert_push("module_breaker", "b", 999 + window, window)
            .await
            .unwrap()
    );
    assert!(
        store
            .claim_admin_alert_push("module_breaker", "b", 1_000 + window, window)
            .await
            .unwrap()
    );
}

#[tokio::test]
async fn only_an_unmuted_manage_server_holder_is_a_recipient() {
    let (store, _guard) = seeded("slimm-alerts-recipients").await;
    let admin = support::app::register_account(&store, "root").await;
    let role = store
        .create_role("ops", Permissions::MANAGE_SERVER, false)
        .await
        .unwrap();
    let other = support::app::register_account(&store, "ops2").await;
    store.assign_role(other.id, role).await.unwrap();
    let _member = support::app::register_account(&store, "nia").await;

    assert_eq!(store.admin_alert_recipients().await.unwrap().len(), 2);

    store.set_admin_alerts_muted(other.id, true).await.unwrap();
    store.set_admin_alerts_muted(other.id, true).await.unwrap();

    assert_eq!(
        store.admin_alert_recipients().await.unwrap(),
        vec![admin.id]
    );
}

#[tokio::test]
async fn the_mute_round_trips_and_setting_it_twice_changes_nothing() {
    let (store, _guard) = seeded("slimm-alerts-mute").await;
    let (admin, _member) = admin_and_member(&store).await;
    let router = support::app::app(store);
    let mute = |muted: bool| {
        request_json(
            "PUT",
            "/space/alerts/mute",
            &admin,
            json!({ "muted": muted }),
        )
    };

    for _ in 0..2 {
        let response = router.clone().oneshot(mute(true)).await.unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(support::app::json_body(response).await["muted"], true);
    }
    assert_eq!(list(&router, &admin).await["muted"], true);

    let response = router.clone().oneshot(mute(false)).await.unwrap();
    assert_eq!(support::app::json_body(response).await["muted"], false);
}

async fn next_alert_frame(ws: &mut Client, within: Duration) -> Option<Value> {
    tokio::time::timeout(within, async {
        loop {
            match ws.next().await {
                Some(Ok(WsMessage::Text(text))) => {
                    let frame: Value = serde_json::from_str(text.as_str()).unwrap();
                    if frame["type"] == "admin_alerts.changed" {
                        return frame;
                    }
                }
                Some(Ok(_)) => continue,
                other => panic!("expected a text frame, got {other:?}"),
            }
        }
    })
    .await
    .ok()
}

#[tokio::test]
async fn the_live_notice_reaches_an_unmuted_admin_and_nobody_else() {
    let (store, _guard) = seeded("slimm-alerts-ws").await;
    let role = store
        .create_role("ops", Permissions::MANAGE_SERVER, false)
        .await
        .unwrap();
    let state = support::app::state(store.clone());
    let (_, admin_ticket, admin) = user_ticket(&store, "root").await;
    store.assign_role(admin, role).await.unwrap();
    let (_, member_ticket, _) = user_ticket(&store, "nia").await;
    let addr = serve(state.clone()).await;
    let mut admin_ws = connect(addr, &admin_ticket).await;
    let mut member_ws = connect(addr, &member_ticket).await;
    let notifier = Notifier::from_state(&state);

    notifier.raise(AlertKind::Livekit, "", "down").await;

    let frame = next_alert_frame(&mut admin_ws, Duration::from_secs(2)).await;
    assert!(frame.is_some(), "an admin hears it live");
    assert!(
        next_alert_frame(&mut member_ws, Duration::from_millis(300))
            .await
            .is_none(),
        "a member must never receive the frame"
    );

    store.set_admin_alerts_muted(admin, true).await.unwrap();
    notifier.raise(AlertKind::DiskLow, "", "low").await;
    assert!(
        next_alert_frame(&mut admin_ws, Duration::from_millis(300))
            .await
            .is_none(),
        "a muted admin hears nothing live"
    );
}

struct StatusDir(
    std::path::PathBuf,
    #[allow(dead_code)] support::TestDirGuard,
);

impl StatusDir {
    fn new() -> Self {
        let (path, guard) = support::TestDirGuard::new("slimm-alerts-status");
        std::fs::create_dir_all(&path).unwrap();
        Self(path, guard)
    }

    fn write(&self, body: &Value) {
        std::fs::write(self.0.join("status.json"), body.to_string()).unwrap();
    }

    fn path(&self) -> String {
        self.0.to_string_lossy().into_owned()
    }
}

async fn monitor_for(state: &http::AppState, dir: &StatusDir, min_disk_mb: u64) -> Monitor {
    Monitor::new(
        state,
        MonitorSettings {
            data_dir: std::env::temp_dir(),
            backup_status_dir: Some(dir.path()),
            min_disk_free_mb: min_disk_mb,
        },
    )
}

fn open_kinds(body: &Value) -> Vec<String> {
    body["alerts"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|a| a["resolved_at"].is_null())
        .map(|a| {
            format!(
                "{}:{}",
                a["kind"].as_str().unwrap(),
                a["subject"].as_str().unwrap()
            )
        })
        .collect()
}

#[tokio::test]
async fn the_monitor_opens_a_backup_alert_for_a_failure_and_closes_it_on_a_pass() {
    let (store, _guard) = seeded("slimm-alerts-monitor-backup").await;
    let (admin, _) = admin_and_member(&store).await;
    let state = support::app::state(store);
    let router = http::router(state.clone());
    let dir = StatusDir::new();
    let now = now_ms();
    let mut monitor = monitor_for(&state, &dir, 0).await;
    dir.write(&json!({ "ok": false, "error": "drill: FAIL", "last_verified_at_ms": now }));

    monitor.tick(now, Duration::from_secs(60)).await;

    assert_eq!(open_kinds(&list(&router, &admin).await), vec!["backup:"]);
    let detail = list(&router, &admin).await["alerts"][0]["detail"].clone();
    assert!(detail.as_str().unwrap().contains("drill: FAIL"), "{detail}");

    dir.write(&json!({ "ok": true, "last_verified_at_ms": now }));
    monitor.tick(now, Duration::from_secs(60)).await;

    assert!(open_kinds(&list(&router, &admin).await).is_empty());
}

#[tokio::test]
async fn the_monitor_calls_a_backup_older_than_48_hours_stale() {
    let (store, _guard) = seeded("slimm-alerts-monitor-stale").await;
    let (admin, _) = admin_and_member(&store).await;
    let state = support::app::state(store);
    let router = http::router(state.clone());
    let dir = StatusDir::new();
    let now = now_ms();
    let mut monitor = monitor_for(&state, &dir, 0).await;
    dir.write(&json!({ "ok": true, "last_verified_at_ms": now - 49 * HOUR_MS }));

    monitor.tick(now, Duration::from_secs(60)).await;

    assert_eq!(open_kinds(&list(&router, &admin).await), vec!["backup:"]);
}

#[tokio::test]
async fn the_monitor_alerts_on_low_disk_and_recovers() {
    let (store, _guard) = seeded("slimm-alerts-monitor-disk").await;
    let (admin, _) = admin_and_member(&store).await;
    let state = support::app::state(store);
    let router = http::router(state.clone());
    let dir = StatusDir::new();
    let now = now_ms();
    let mut impossible = monitor_for(&state, &dir, u64::MAX / (1024 * 1024)).await;

    impossible.tick(now, Duration::from_secs(60)).await;
    assert_eq!(open_kinds(&list(&router, &admin).await), vec!["disk_low:"]);

    let mut fine = monitor_for(&state, &dir, 1).await;
    fine.tick(now, Duration::from_secs(60)).await;
    assert!(open_kinds(&list(&router, &admin).await).is_empty());
}

#[tokio::test]
async fn a_sweep_that_stopped_recording_is_an_alert_once_it_has_had_its_turns() {
    let (store, _guard) = seeded("slimm-alerts-monitor-sweeps").await;
    let (admin, _) = admin_and_member(&store).await;
    let state = support::app::state(store.clone());
    let router = http::router(state.clone());
    let dir = StatusDir::new();
    let now = now_ms();
    let mut monitor = monitor_for(&state, &dir, 0).await;

    monitor.tick(now, Duration::from_secs(3600)).await;
    assert!(
        open_kinds(&list(&router, &admin).await).is_empty(),
        "a young process blames nobody"
    );

    monitor.tick(now, Duration::from_secs(72 * 3600)).await;
    assert!(open_kinds(&list(&router, &admin).await).contains(&"sweep_failing:token".to_owned()));

    store.record_sweep_run("token", 0).await.unwrap();
    monitor.tick(now, Duration::from_secs(72 * 3600)).await;
    assert!(!open_kinds(&list(&router, &admin).await).contains(&"sweep_failing:token".to_owned()));
}

#[tokio::test]
async fn a_module_breaker_alert_closes_when_the_module_is_gone() {
    let (store, _guard) = seeded("slimm-alerts-monitor-module").await;
    let (admin, _) = admin_and_member(&store).await;
    let state = support::app::state(store);
    let router = http::router(state.clone());
    let dir = StatusDir::new();
    let notifier = Notifier::from_state(&state);
    notifier
        .raise(AlertKind::ModuleBreaker, "ghost", "ghost was turned off.")
        .await;
    assert_eq!(
        open_kinds(&list(&router, &admin).await),
        vec!["module_breaker:ghost"]
    );
    let mut monitor = monitor_for(&state, &dir, 0).await;

    monitor.tick(now_ms(), Duration::from_secs(60)).await;

    assert!(open_kinds(&list(&router, &admin).await).is_empty());
}

#[tokio::test]
async fn storage_reports_the_backup_the_container_wrote() {
    let (store, _guard) = seeded("slimm-alerts-storage").await;
    let (admin, _) = admin_and_member(&store).await;
    let dir = StatusDir::new();
    let now = now_ms();
    let router = support::app::app(store).layer(axum::Extension(BackupStatusDir(Some(dir.path()))));
    let backup = || async {
        let (status, body) = call(&router, "GET", "/space/storage", Some(&admin), None).await;
        assert_eq!(status, StatusCode::OK, "{body}");
        body["backup"].clone()
    };

    assert_eq!(backup().await["state"], "never");

    dir.write(&json!({ "ok": true, "last_verified_at_ms": now - 14 * HOUR_MS, "last_verified_bytes": 4096 }));
    let verified = backup().await;
    assert_eq!(verified["state"], "verified");
    assert_eq!(verified["verified_bytes"], 4096);
    assert_eq!(verified["stale"], false);

    dir.write(&json!({ "ok": false, "error": "backup: no database", "last_verified_at_ms": now - 60 * HOUR_MS }));
    let failed = backup().await;
    assert_eq!(failed["state"], "failed");
    assert_eq!(failed["error"], "backup: no database");
    assert_eq!(failed["stale"], true);
}

#[tokio::test]
async fn storage_without_a_status_directory_says_not_configured() {
    let (store, _guard) = seeded("slimm-alerts-storage-unset").await;
    let (admin, _) = admin_and_member(&store).await;
    let router = support::app::app(store);

    let (_, body) = call(&router, "GET", "/space/storage", Some(&admin), None).await;

    assert_eq!(body["backup"]["state"], "not_configured");
}
