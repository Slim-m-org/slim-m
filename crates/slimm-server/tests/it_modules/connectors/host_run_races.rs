// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Host-run lifecycle edges: the monitor's pass gate, a failed list, store errors on uninstall,
//! and the reason a turned-off connector keeps.

use std::time::Duration;

use axum::http::StatusCode;
use serde_json::{Value, json};

use super::harness::ID;
use super::host_run_world::host_world;

fn approval() -> Value {
    json!({"egress": [{"host": "api.example.com", "port": 443}, {"host": "jellyfin.lan", "port": 8096}], "egress_private": true})
}

#[tokio::test]
async fn install_waits_for_a_monitor_pass_instead_of_racing_it() {
    let w = host_world("slimm-hostrun-gate-install", true, true).await;
    let runner = w.state.dock.host_run().unwrap();
    let pass = runner.pause_monitor().await;

    let (installed, ()) = tokio::join!(w.install(approval()), async {
        tokio::time::sleep(Duration::from_millis(300)).await;
        assert!(
            w.fake.calls("create").is_empty(),
            "no create while a pass holds the gate"
        );
        drop(pass);
    });

    assert_eq!(installed.0, StatusCode::OK, "{}", installed.1);
    assert_eq!(w.fake.calls("create").len(), 1);
}

#[tokio::test]
async fn enable_waits_for_a_monitor_pass_instead_of_racing_it() {
    let w = host_world("slimm-hostrun-gate-enable", true, true).await;
    assert_eq!(w.install(approval()).await.0, StatusCode::OK);
    let runner = w.state.dock.host_run().unwrap();
    let pass = runner.pause_monitor().await;
    let uri = format!("/space/dock/modules/{ID}/enable");

    let (enabled, ()) = tokio::join!(w.as_owner("POST", &uri, None), async {
        tokio::time::sleep(Duration::from_millis(300)).await;
        assert!(
            w.fake.calls("start").is_empty(),
            "no start while a pass holds the gate"
        );
        drop(pass);
    });

    assert_eq!(enabled.0, StatusCode::OK, "{}", enabled.1);
    assert_eq!(w.fake.calls("start").len(), 1);
}

#[tokio::test]
async fn enable_with_a_failed_list_keeps_the_container_and_its_token() {
    let w = host_world("slimm-hostrun-enable-list-fails", true, true).await;
    assert_eq!(w.install(approval()).await.0, StatusCode::OK);
    let token = w.last_token();
    w.fake.with(|f| f.fail_list = true);

    let (status, body) = w
        .as_owner("POST", &format!("/space/dock/modules/{ID}/enable"), None)
        .await;

    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(w.fake.calls("create").len(), 1, "no container made again");
    assert_eq!(w.last_token(), token);
    assert_eq!(w.fake.calls("remove").len(), 1, "only install's cleanup");
    assert!(w.status().await["last_error"].is_string());
}

#[tokio::test]
async fn a_store_error_before_uninstall_fails_the_uninstall() {
    let w = host_world("slimm-hostrun-uninstall-store-error", true, true).await;
    w.running().await;
    sqlx::query("ALTER TABLE connector_host_runs RENAME TO connector_host_runs_away")
        .execute(&w.pool)
        .await
        .unwrap();
    let uri = format!("/space/dock/modules/{ID}/install?delete_data=true");

    let (status, body) = w.as_owner("DELETE", &uri, None).await;

    sqlx::query("ALTER TABLE connector_host_runs_away RENAME TO connector_host_runs")
        .execute(&w.pool)
        .await
        .unwrap();
    assert!(status.is_server_error(), "{status} {body}");
    assert!(w.store.installed_module(ID).await.unwrap().is_some());
}

#[tokio::test]
async fn a_connector_turned_off_without_a_health_row_keeps_its_reason() {
    let w = host_world("slimm-hostrun-reason-no-row", true, true).await;
    w.running().await;
    let reason = "it stopped five times in ten minutes";

    let off = w
        .store
        .turn_off_host_run(ID, reason, slimm_server::store::TurnedOff::VolumeFull)
        .await
        .unwrap();

    assert!(off);
    let health = w.store.module_health().await.unwrap();
    assert_eq!(health[ID].disabled_reason.as_deref(), Some(reason));
}
