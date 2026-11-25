// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The volume sweep, the start and create verbs and the readiness refresh against a runtime stand-in.

use std::time::Duration;

use serde_json::json;

use super::fake_runtime::{Docker, serve};
use super::volumes::{BLIND_CHECKS_BEFORE_STOPPING, MIB};

const IMAGE: &str = "ghcr.io/slim-m-org/probe@sha256:0000000000000000000000000000000000000000000000000000000000000000";

fn running(ids: &[&str]) -> Vec<(String, bool)> {
    ids.iter().map(|id| ((*id).to_owned(), true)).collect()
}

fn set(docker: &std::sync::Mutex<Docker>, change: impl FnOnce(&mut Docker)) {
    change(&mut docker.lock().unwrap());
}

#[tokio::test]
async fn connectors_with_a_volume_are_stopped_when_they_cannot_be_measured_for_long() {
    let (supervisor, docker, dir) = serve().await;
    set(&docker, |d| {
        d.connectors = running(&["c1"]);
        d.helper_fails = true;
    });
    for _ in 1..BLIND_CHECKS_BEFORE_STOPPING {
        assert!(supervisor.check_volumes().await.is_err());
    }
    assert!(docker.lock().unwrap().stopped.is_empty());
    assert!(supervisor.check_volumes().await.is_err());
    assert_eq!(docker.lock().unwrap().stopped, ["c1"], "fails closed");

    set(&docker, |d| {
        d.helper_fails = false;
        d.sizes.insert("c1".into(), MIB);
        d.stopped.clear();
    });
    assert!(supervisor.check_volumes().await.is_ok());
    set(&docker, |d| d.helper_fails = true);
    assert!(supervisor.check_volumes().await.is_err());
    assert!(
        docker.lock().unwrap().stopped.is_empty(),
        "a measured sweep starts the count again"
    );
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn a_connector_with_no_size_report_is_unmeasured_not_empty() {
    let (supervisor, docker, dir) = serve().await;
    set(&docker, |d| d.connectors = running(&["c1"]));
    assert!(supervisor.check_volumes().await.is_err());
    assert_eq!(supervisor.usage("c1").await, None, "no size was invented");
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn a_connector_over_its_allocated_ceiling_is_stopped() {
    let (supervisor, docker, dir) = serve().await;
    set(&docker, |d| {
        d.connectors = running(&["c1", "c2"]);
        d.sizes.insert("c1".into(), 512 * MIB);
        d.sizes.insert("c2".into(), MIB);
    });
    supervisor.check_volumes().await.unwrap();
    assert_eq!(docker.lock().unwrap().stopped, ["c1"]);
    assert_eq!(supervisor.usage("c2").await.unwrap().bytes, MIB);
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn one_failing_stop_does_not_spare_the_connectors_after_it() {
    let (supervisor, docker, dir) = serve().await;
    set(&docker, |d| {
        d.connectors = running(&["c1", "c2", "c3"]);
        for id in ["c1", "c2", "c3"] {
            d.sizes.insert(id.into(), 512 * MIB);
        }
        d.stop_fails.insert("c1".into());
    });
    assert!(supervisor.check_volumes().await.is_err());
    assert_eq!(docker.lock().unwrap().stopped, ["c2", "c3"]);
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn one_failing_stop_does_not_spare_the_unmeasurable_connectors_after_it() {
    let (supervisor, docker, dir) = serve().await;
    set(&docker, |d| {
        d.connectors = running(&["c1", "c2"]);
        d.helper_fails = true;
        d.stop_fails.insert("c1".into());
    });
    for _ in 0..BLIND_CHECKS_BEFORE_STOPPING {
        assert!(supervisor.check_volumes().await.is_err());
    }
    assert_eq!(docker.lock().unwrap().stopped, ["c2"]);
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn start_recreates_a_network_the_runtime_dropped() {
    let (supervisor, docker, dir) = serve().await;
    set(&docker, |d| {
        d.connectors = vec![("c1".into(), false)];
        d.sizes.insert("c1".into(), 0);
    });
    let started = supervisor.start("c1").await;
    let requests = docker.lock().unwrap().requests.clone();
    assert!(
        requests.contains(&"POST /networks/create".to_owned()),
        "{started:?} {requests:?}"
    );
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn a_slow_image_pull_does_not_hold_up_stop_or_the_volume_sweep() {
    let (supervisor, docker, dir) = serve().await;
    set(&docker, |d| {
        d.connectors = running(&["c1"]);
        d.sizes.insert("c1".into(), MIB);
        d.image_pull_hangs = true;
    });
    let request = serde_json::from_value(json!({"image": IMAGE})).unwrap();
    let creating = tokio::spawn({
        let supervisor = supervisor.clone();
        async move { supervisor.create("c2", request).await }
    });
    tokio::time::sleep(Duration::from_millis(300)).await;
    let free = async {
        supervisor.stop("c1", 1).await.unwrap();
        supervisor.check_volumes().await.unwrap();
    };
    tokio::time::timeout(Duration::from_secs(5), free)
        .await
        .expect("stop and the sweep wait for the pull");
    creating.abort();
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn concurrent_readiness_refreshes_never_share_the_probe_network() {
    let (supervisor, docker, dir) = serve().await;
    let (a, b) = tokio::join!(
        supervisor.refresh_readiness(),
        supervisor.refresh_readiness()
    );
    a.unwrap();
    b.unwrap();
    assert_eq!(docker.lock().unwrap().probes_most, 1);
    std::fs::remove_dir_all(dir).unwrap();
}
