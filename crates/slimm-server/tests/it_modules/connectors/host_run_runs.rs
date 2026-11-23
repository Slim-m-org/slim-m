// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A host-run connector's commands and panels (decisions 0134 and 0090): its container
//! connects with the token it was handed and gets `connector.run` like any connector, and
//! one the supervisor reports as not running reads as offline at once.

use std::time::{Duration, Instant};

use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::permissions::Permissions;

use super::harness::ID;
use super::host_run_world::{HostWorld, host_world};
use super::runs_world::next_run;
use crate::support;
use support::app::{Account, call};

async fn member(w: &HostWorld) -> Account {
    let member = support::app::register_account(&w.store, "member").await;
    let role = w
        .store
        .create_role("players", Permissions::NONE, false)
        .await
        .unwrap();
    w.store.assign_role(member.id, role).await.unwrap();
    w.store
        .grant_module_permission(role, ID, "use")
        .await
        .unwrap();
    member
}

async fn run(w: &HostWorld, member: &Account) -> (StatusCode, Value) {
    let uri = format!("/modules/{ID}/commands/servers");
    call(
        &w.router,
        "POST",
        &uri,
        Some(&member.token),
        Some(json!({"input": ""})),
    )
    .await
}

/// The container's socket, opened with the token the host put in its environment.
async fn container_socket(w: &HostWorld, addr: std::net::SocketAddr) -> support::ws::Client {
    let token = w.last_token();
    let (status, body) = call(&w.router, "POST", "/auth/ws-ticket", Some(&token), None).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    support::ws::connect(addr, body["ticket"].as_str().unwrap()).await
}

#[tokio::test]
async fn a_running_host_run_connector_gets_its_runs_with_the_token_it_was_handed() {
    let w = host_world("slimm-hostrun-runs", true, true).await;
    w.running().await;
    let member = member(&w).await;
    let addr = support::ws::serve(w.state.clone()).await;
    let mut ws = container_socket(&w, addr).await;
    let token = w.last_token();
    let connector = async {
        let frame = next_run(&mut ws)
            .await
            .expect("the container is sent the run");
        let uri = format!("/connectors/me/runs/{}", frame["run_id"].as_str().unwrap());
        let answer = json!({"ok": true, "output": "two servers up"});
        let (status, _) = call(&w.router, "POST", &uri, Some(&token), Some(answer)).await;
        assert_eq!(status, StatusCode::NO_CONTENT);
    };
    let (ran, ()) = tokio::join!(run(&w, &member), connector);
    assert_eq!(
        ran,
        (
            StatusCode::OK,
            json!({"ok": true, "output": "two servers up"})
        )
    );
}

#[tokio::test]
async fn a_crashed_host_run_connector_is_offline_at_once_even_with_a_lingering_socket() {
    let w = host_world("slimm-hostrun-runs-crash", true, true).await;
    let run_id = w.running().await;
    let member = member(&w).await;
    let addr = support::ws::serve(w.state.clone()).await;
    let mut ws = container_socket(&w, addr).await;
    w.fake.set_state(&run_id, "exited", "2026-11-22T10:00:01Z");
    w.tick().await;
    let started = Instant::now();
    let (status, ran) = run(&w, &member).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(ran, json!({"ok": false, "error": "Jellyfin is offline"}));
    assert!(started.elapsed() < Duration::from_secs(2));
    assert!(
        next_run(&mut ws).await.is_none(),
        "nothing is sent to a crashed connector"
    );
}

#[tokio::test]
async fn a_stopped_or_crash_disabled_host_run_connector_is_sent_nothing() {
    let w = host_world("slimm-hostrun-runs-off", true, true).await;
    let run_id = w.running().await;
    let member = member(&w).await;
    for i in 0..5 {
        w.fake
            .set_state(&run_id, "exited", &format!("2026-11-22T10:00:0{i}Z"));
        w.tick().await;
    }
    let started = Instant::now();
    let (status, ran) = run(&w, &member).await;
    assert!(started.elapsed() < Duration::from_secs(2));
    assert_ne!(
        status,
        StatusCode::OK,
        "a turned-off connector is refused like a disabled module: {ran}"
    );
}
