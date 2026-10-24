// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The event lane and the circuit breaker (decision 0091): a bounded queue,
//! a lane apart from members' commands, and a module switched off after five
//! failed background runs in a row.

use std::time::{Duration, Instant};

use axum::body::Body;
use axum::http::Request;
use serde_json::Value;
use slimm_server::http::spawn_module_events;
use slimm_server::hub::Event;
use slimm_server::ids::UserId;
use slimm_server::permissions::Permissions;

mod support;
use support::module_events_world::EventModule;
use support::module_world::{Install, World, world};
use support::wait::wait_for;
use support::wasm_fixtures::{busy_ok_wasm, canned_ok_wasm, joined_fails_wasm};

/// Loop turns for a run that holds its lane slot for a few hundred milliseconds.
const SPIN: u32 = 4_000_000;

async fn admin_token(w: &World) -> String {
    let role = w
        .store
        .create_role("admin", Permissions::ADMINISTRATOR, false)
        .await
        .unwrap();
    let admin = w.store.create_user("root", "Root").await.unwrap();
    w.store.assign_role(admin.id, role).await.unwrap();
    w.store
        .open_session(admin.id, "laptop")
        .await
        .unwrap()
        .access_token
}

async fn failures_of(w: &World, module: &str) -> i64 {
    let health = w.store.module_health().await.unwrap();
    health.get(module).map_or(0, |h| h.consecutive_failures)
}

async fn health_of(w: &World, token: &str, module: &str) -> Value {
    let request = Request::builder()
        .uri("/space/dock/installed")
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap();
    let listed = w.send(request).await;
    listed
        .as_array()
        .and_then(|all| all.iter().find(|m| m["id"] == module).cloned())
        .expect("the module is listed")
}

fn join() -> Event {
    Event::MemberJoined(UserId::generate())
}

fn leave() -> Event {
    Event::MemberRemoved(UserId::generate())
}

#[tokio::test]
async fn five_failures_in_a_row_switch_a_module_off_and_a_success_or_enabling_resets_the_count() {
    let w = world("slimm-modlane-breaker").await;
    let _consumer = spawn_module_events(w.state.clone());
    let token = admin_token(&w).await;
    let bot = w
        .install_event_module(EventModule {
            id: "flaky",
            wasm: joined_fails_wasm(),
            subscribes: &["member.joined", "member.left"],
            approved: &["events"],
        })
        .await;

    for _ in 0..4 {
        w.hub.publish(join());
    }
    wait_for("four failed runs", || async {
        (failures_of(&w, "flaky").await == 4).then_some(())
    })
    .await;
    let module = health_of(&w, &token, "flaky").await;
    assert_eq!(module["enabled"], true, "four is not enough");

    w.hub.publish(leave());
    wait_for("a success to reset the count", || async {
        (failures_of(&w, "flaky").await == 0).then_some(())
    })
    .await;

    for _ in 0..6 {
        w.hub.publish(join());
    }
    wait_for("the module to be switched off", || async {
        let module = w.store.installed_module("flaky").await.unwrap().unwrap();
        (!module.enabled).then_some(())
    })
    .await;
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(
        w.event_runs("flaky").await,
        10,
        "exactly five more runs, then none"
    );
    let module = health_of(&w, &token, "flaky").await;
    assert_eq!(module["consecutive_failures"], 5);
    assert!(
        module["disabled_reason"]
            .as_str()
            .unwrap()
            .contains("5 failed background runs"),
        "{module}"
    );
    let audit = w.store.admin_changes(None, 10).await.unwrap();
    let entry = audit
        .iter()
        .find(|e| e.action == "module.auto_disable")
        .expect("audited");
    assert_eq!(entry.target_id.as_deref(), Some("flaky"));
    assert_eq!(entry.actor_id, Some(bot));

    w.store.set_module_enabled("flaky", true).await.unwrap();
    let module = health_of(&w, &token, "flaky").await;
    assert_eq!(module["consecutive_failures"], 0, "enabling again resets");
    assert!(module.get("disabled_reason").is_none());
}

#[tokio::test]
async fn a_full_queue_drops_the_oldest_events_and_the_admin_sees_the_count() {
    let w = world("slimm-modlane-overflow").await;
    let _consumer = spawn_module_events(w.state.clone());
    let token = admin_token(&w).await;
    w.install_event_module(EventModule {
        id: "slowpoke",
        wasm: busy_ok_wasm(SPIN),
        subscribes: &["member.joined"],
        approved: &["events"],
    })
    .await;

    for _ in 0..300 {
        w.hub.publish(join());
        tokio::task::yield_now().await;
    }
    let dropped = wait_for("the drop count to be stored", || async {
        let health = w.store.module_health().await.unwrap();
        let n = health.get("slowpoke").map_or(0, |h| h.events_dropped);
        (n > 0).then_some(n)
    })
    .await;
    assert!(dropped > 0);
    tokio::time::sleep(Duration::from_millis(500)).await;
    let health = w.store.module_health().await.unwrap();
    let stored = health["slowpoke"].events_dropped;
    let shown = health_of(&w, &token, "slowpoke").await["events_dropped"].as_i64();
    assert_eq!(shown, Some(stored), "the admin's list carries the count");
    assert!(
        stored <= 300 - 256,
        "no more than the overflow was dropped: {stored}"
    );
}

#[tokio::test]
async fn a_saturated_event_lane_does_not_stop_a_members_command() {
    let w = world("slimm-modlane-saturated").await;
    let _consumer = spawn_module_events(w.state.clone());
    w.install(Install {
        id: "quick",
        wasm: canned_ok_wasm("fast"),
        declared: &[],
        approved_host: &[],
    })
    .await;
    let slow = ["slow-a", "slow-b", "slow-c"];
    for id in slow {
        w.install_event_module(EventModule {
            id,
            wasm: busy_ok_wasm(SPIN),
            subscribes: &["member.joined"],
            approved: &["events"],
        })
        .await;
    }
    let events_done = || async {
        let mut done = 0;
        for id in slow {
            done += w.event_runs(id).await;
        }
        done
    };

    let started = Instant::now();
    w.hub.publish(join());
    w.hub.publish(join());
    wait_for("the lane to fill", || async {
        (events_done().await >= 1 || started.elapsed() > Duration::from_millis(50)).then_some(())
    })
    .await;

    let mut slowest = Duration::ZERO;
    for _ in 0..5 {
        let asked = Instant::now();
        assert_eq!(w.answer("quick").await, "fast");
        slowest = slowest.max(asked.elapsed());
    }
    let while_busy = events_done().await;
    let lane_work = started.elapsed();
    eprintln!(
        "slowest member command {slowest:?} while {while_busy}/6 event runs finished after {lane_work:?}"
    );
    assert!(
        while_busy < 6,
        "the lane was still saturated when the commands ran"
    );

    wait_for("all six event runs", || async {
        (events_done().await == 6).then_some(())
    })
    .await;
    let one_run = started.elapsed() / 3;
    assert!(
        slowest < one_run / 2,
        "a command waited {slowest:?}; one event run takes about {one_run:?}"
    );
}
