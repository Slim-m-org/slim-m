// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The host-run monitor (decision 0134): restart with backoff, the crash breaker,
//! reconciliation, and a supervisor or runtime that is down.

use axum::http::StatusCode;
use serde_json::json;

use super::fake_supervisor;
use super::harness::ID;
use super::host_run_world::host_world;

#[tokio::test]
async fn a_crash_is_restarted_after_its_backoff() {
    let w = host_world("slimm-hostrun-restart", true, true).await;
    let run_id = w.running().await;
    let starts = w.fake.calls("start").len();
    w.fake.set_state(&run_id, "exited", "2026-11-22T10:00:01Z");
    w.tick().await;
    assert_eq!(
        w.fake.calls("start").len(),
        starts,
        "the first restart waits a second"
    );
    assert_eq!(w.status().await["state"], json!("crashed"));
    tokio::time::sleep(std::time::Duration::from_millis(1100)).await;
    w.tick().await;
    assert_eq!(w.fake.calls("start").len(), starts + 1);
    assert_eq!(w.fake.state(&run_id).as_deref(), Some("running"));
    assert_eq!(w.status().await["restarts"], json!(1));
}

#[tokio::test]
async fn five_crashes_in_ten_minutes_turn_it_off_with_an_alert_and_audit_row() {
    let w = host_world("slimm-hostrun-breaker", true, true).await;
    let run_id = w.running().await;
    for i in 0..5 {
        w.fake
            .set_state(&run_id, "exited", &format!("2026-11-22T10:00:0{i}Z"));
        w.tick().await;
    }
    let module = w.store.installed_module(ID).await.unwrap().unwrap();
    assert!(!module.enabled, "the breaker disabled it");
    let status = w.status().await;
    assert_eq!(status["state"], json!("disabled_after_crashes"), "{status}");
    assert!(status["last_error"].as_str().unwrap().contains("5 crashes"));
    let audit = w.store.admin_changes(None, 50).await.unwrap();
    assert!(
        audit
            .iter()
            .any(|e| e.action == "module.auto_disable" && e.target_id.as_deref() == Some(ID)),
        "{audit:?}"
    );
    let starts = w.fake.calls("start").len();
    w.tick().await;
    assert_eq!(
        w.fake.calls("start").len(),
        starts,
        "a disabled connector is not restarted"
    );
    let (status, body) = w
        .as_owner("POST", &format!("/space/dock/modules/{ID}/enable"), None)
        .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(
        w.status().await["state"],
        json!("running"),
        "enabling re-arms the breaker"
    );
}

/// M2: the supervisor stops a connector whose volume passed its ceiling; the server turns it
/// off with the breaker's alert and audit row and does not restart it.
#[tokio::test]
async fn a_full_volume_turns_it_off_and_it_is_not_restarted() {
    let w = host_world("slimm-hostrun-volume", true, true).await;
    let run_id = w.running().await;
    let (_, create) = w.fake.calls("create").last().cloned().unwrap();
    assert_eq!(create["limits"]["volume_mib"], json!(64), "{create}");
    w.fake.with(|f| {
        f.containers.insert(
            run_id.clone(),
            json!({"state": "exited", "finished_at": "2026-11-22T10:00:01Z", "exit_code": 137,
                   "volume_bytes": 70 * 1024 * 1024, "volume_over_limit": true}),
        );
    });
    let starts = w.fake.calls("start").len();
    w.tick().await;
    tokio::time::sleep(std::time::Duration::from_millis(1100)).await;
    w.tick().await;
    assert_eq!(
        w.fake.calls("start").len(),
        starts,
        "a full connector is not restarted"
    );
    let module = w.store.installed_module(ID).await.unwrap().unwrap();
    assert!(!module.enabled, "it was turned off");
    let status = w.status().await;
    assert_eq!(status["state"], json!("refused"), "{status}");
    assert!(
        status["last_error"].as_str().unwrap().contains("64 MiB"),
        "{status}"
    );
    assert_eq!(status["volume_bytes"], json!(70 * 1024 * 1024));
    let audit = w.store.admin_changes(None, 50).await.unwrap();
    assert!(
        audit.iter().any(|e| e.action == "module.auto_disable"
            && e.target_id.as_deref() == Some(ID)
            && e.detail.contains("volume_bytes")),
        "{audit:?}"
    );
}

#[tokio::test]
async fn reconcile_creates_what_is_missing_and_removes_what_it_has_no_record_of() {
    let w = host_world("slimm-hostrun-reconcile", true, true).await;
    let run_id = w.running().await;
    let first_token = w.last_token();
    w.fake.with(|f| {
        f.containers.clear();
        f.containers.insert(
            "0196f2a0-0000-7000-8000-00000000dead".into(),
            json!({"state": "running"}),
        );
    });
    w.tick().await;
    assert_eq!(
        w.fake.state(&run_id).as_deref(),
        Some("running"),
        "the missing container was made again"
    );
    assert_ne!(
        w.last_token(),
        first_token,
        "a container made again gets a new token"
    );
    let (status, _) =
        crate::support::app::call(&w.router, "GET", "/connectors/me", Some(&first_token), None)
            .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED, "the old token is revoked");
    let removes = w.fake.calls("remove");
    let orphan = removes
        .iter()
        .find(|(id, _)| id.ends_with("dead"))
        .expect("the orphan was removed");
    assert_eq!(
        orphan.1["keep_volume"],
        json!(true),
        "an orphan's volume is kept"
    );
}

#[tokio::test]
async fn a_down_supervisor_refuses_install_and_start_and_recovers() {
    let w = host_world("slimm-hostrun-down", true, false).await;
    let (_, runtime) = w
        .as_owner("GET", "/space/dock/connector-runtime", None)
        .await;
    assert_eq!(runtime["available"], json!(false), "{runtime}");
    let (status, body) = w.install(json!({"egress": []})).await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE, "{body}");
    assert_eq!(body["code"], json!("connector_runtime_unavailable"));
    fake_supervisor::serve(w.fake.clone(), &w.socket).await;
    w.tick().await;
    let run_id = w.running().await;
    assert_eq!(w.fake.state(&run_id).as_deref(), Some("running"));
}

#[tokio::test]
async fn a_down_runtime_shows_as_unavailable_and_blocks_start() {
    let w = host_world("slimm-hostrun-runtime", true, true).await;
    w.running().await;
    let (status, _) = w
        .as_owner("POST", &format!("/space/dock/modules/{ID}/disable"), None)
        .await;
    assert_eq!(
        status,
        StatusCode::OK,
        "disabling never waits on the runtime"
    );
    w.fake.with(|f| f.runtime_down = true);
    w.tick().await;
    assert_eq!(w.status().await["state"], json!("runtime_unavailable"));
    let (status, body) = w
        .as_owner("POST", &format!("/space/dock/modules/{ID}/enable"), None)
        .await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE, "{body}");
    let (status, _) = w
        .as_owner(
            "GET",
            &format!("/space/dock/modules/{ID}/host-run/logs"),
            None,
        )
        .await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    w.fake.with(|f| f.runtime_down = false);
    w.tick().await;
    let (status, _) = w
        .as_owner("POST", &format!("/space/dock/modules/{ID}/enable"), None)
        .await;
    assert_eq!(status, StatusCode::OK);
}

#[tokio::test]
async fn a_disabled_connector_left_running_is_stopped() {
    let w = host_world("slimm-hostrun-stopdrift", true, true).await;
    let run_id = w.running().await;
    w.store.set_module_enabled(ID, false).await.unwrap();
    w.tick().await;
    assert_eq!(w.fake.state(&run_id).as_deref(), Some("exited"));
}
