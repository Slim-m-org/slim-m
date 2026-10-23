// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Slot fills have a lane of their own (decision 0091): they never count
//! toward the circuit breaker, and neither they nor the runs they would
//! otherwise queue behind (events, members' commands) wait on each other.

use std::time::{Duration, Instant};

use axum::body::Body;
use axum::http::Request;
use serde_json::json;
use slimm_server::http::spawn_module_events;
use slimm_server::hub::Event;
use slimm_server::ids::UserId;
use slimm_server::store::{
    DockProvenance, InstallModuleRequest, ModulePlatform, ModuleRuntimeLimits, ModuleSlot,
};
use tower::ServiceExt;

mod support;
use support::module_events_world::EventModule;
use support::module_world::{Install, World, world};
use support::wait::wait_for;
use support::wasm_fixtures::{
    busy_ok_wasm, canned_ok_wasm, canned_slot_wasm, refusing_wasm, sha256_hex,
};

/// Loop turns for a run that holds its lane slot for a few hundred milliseconds.
const SPIN: u32 = 4_000_000;

async fn install_slot_module(w: &World, id: &str, wasm: &[u8]) {
    let sha256 = sha256_hex(wasm);
    let platform = ModulePlatform {
        addon_api: 1,
        slots: vec![ModuleSlot {
            kind: "member.badge".into(),
            name: "level".into(),
            title: None,
        }],
        ..ModulePlatform::default()
    };
    w.store
        .install_module_from_dock(
            InstallModuleRequest {
                id,
                name: "Levels",
                version: "0.1.0",
                artifact_sha256: &sha256,
                approved_capabilities: &[],
                runtime_limits: &ModuleRuntimeLimits::default(),
                permissions: &[],
                extension_points: &[],
            },
            wasm,
            &DockProvenance {
                host_capabilities: &[],
                source_repo: None,
                network_hosts: &[],
                local_network_approved: false,
                schedules: &[],
                platform: &platform,
            },
        )
        .await
        .unwrap();
    w.store.set_module_enabled(id, true).await.unwrap();
}

async fn badges_for(w: &World, token: &str, fresh: usize) {
    let mut ids = Vec::new();
    for i in 0..fresh {
        let name = format!("m{}-{i}", UserId::generate());
        ids.push(
            w.store
                .create_user(&name, &name)
                .await
                .unwrap()
                .id
                .to_string(),
        );
    }
    let request = Request::builder()
        .uri(format!("/space/dock/slots/badges?ids={}", ids.join(",")))
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap();
    let response = w.router.clone().oneshot(request).await.unwrap();
    assert!(response.status().is_success());
}

async fn viewer_token(w: &World, name: &str) -> String {
    let user = w.store.create_user(name, name).await.unwrap();
    w.store
        .open_session(user.id, "phone")
        .await
        .unwrap()
        .access_token
}

async fn failures_of(w: &World, module: &str) -> i64 {
    let health = w.store.module_health().await.unwrap();
    health.get(module).map_or(0, |h| h.consecutive_failures)
}

#[tokio::test]
async fn failing_slot_requests_never_disable_the_module() {
    let w = world("slimm-slotlane-breaker").await;
    install_slot_module(&w, "broken", &refusing_wasm()).await;
    for _ in 0..6 {
        badges_for(&w, &w.token, 1).await;
    }
    assert_eq!(failures_of(&w, "broken").await, 0);
    let module = w.store.installed_module("broken").await.unwrap().unwrap();
    assert!(
        module.enabled,
        "six failed slot runs switched the module off"
    );
    let stats = w.store.module_run_stats().await.unwrap();
    let slot = stats["broken"]
        .iter()
        .find(|s| s.command == "@slot")
        .unwrap();
    assert_eq!((slot.run_count, slot.failure_count), (6, 6));
}

#[tokio::test]
async fn a_slot_success_does_not_reset_an_event_failure_streak() {
    let w = world("slimm-slotlane-streak").await;
    let ok = canned_slot_wasm(&json!({ "$slim": "slot/1", "items": {} }));
    install_slot_module(&w, "levels", &ok).await;
    for _ in 0..3 {
        w.store
            .record_module_background_failure("levels")
            .await
            .unwrap();
    }
    badges_for(&w, &w.token, 1).await;
    assert_eq!(failures_of(&w, "levels").await, 3);
}

#[tokio::test]
async fn a_junk_slot_reply_is_a_failed_run_in_the_stats_and_not_a_success_for_the_breaker() {
    let w = world("slimm-slotlane-junk").await;
    install_slot_module(&w, "junky", &canned_ok_wasm("not slot/1")).await;
    for _ in 0..2 {
        w.store
            .record_module_background_failure("junky")
            .await
            .unwrap();
    }
    badges_for(&w, &w.token, 1).await;
    assert_eq!(failures_of(&w, "junky").await, 2);
    let stats = w.store.module_run_stats().await.unwrap();
    let slot = stats["junky"]
        .iter()
        .find(|s| s.command == "@slot")
        .unwrap();
    assert!(slot.failure_count >= 1);
}

#[tokio::test]
async fn a_saturated_event_lane_does_not_delay_slots() {
    let w = world("slimm-slotlane-events-busy").await;
    let _consumer = spawn_module_events(w.state.clone());
    let ok = canned_slot_wasm(&json!({ "$slim": "slot/1", "items": {} }));
    install_slot_module(&w, "levels", &ok).await;
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
    let started = Instant::now();
    w.hub.publish(Event::MemberJoined(UserId::generate()));
    tokio::time::sleep(Duration::from_millis(60)).await;

    let asked = Instant::now();
    badges_for(&w, &w.token, 1).await;
    let slot_wait = asked.elapsed();
    wait_for("the event runs", || async {
        let mut done = 0;
        for id in slow {
            done += w.event_runs(id).await;
        }
        (done == 3).then_some(())
    })
    .await;
    let one_run = started.elapsed() / 2;
    eprintln!("slot waited {slot_wait:?} while an event run takes about {one_run:?}");
    assert!(
        slot_wait < one_run / 2,
        "a slot waited {slot_wait:?} behind events"
    );
}

#[tokio::test]
async fn a_saturated_slot_lane_does_not_delay_events_or_member_commands() {
    let w = world("slimm-slotlane-slots-busy").await;
    let _consumer = spawn_module_events(w.state.clone());
    install_slot_module(&w, "slow-slot", &busy_ok_wasm(SPIN)).await;
    w.install(Install {
        id: "quick",
        wasm: canned_ok_wasm("fast"),
        declared: &[],
        approved_host: &[],
    })
    .await;
    w.install_event_module(EventModule {
        id: "listener",
        wasm: canned_ok_wasm("ok"),
        subscribes: &["member.joined"],
        approved: &["events"],
    })
    .await;
    let started = Instant::now();
    let viewers = [
        viewer_token(&w, "vera").await,
        viewer_token(&w, "walt").await,
    ];
    let shown = w.store.create_user("shown", "Shown").await.unwrap().id;
    let fills: Vec<_> = viewers
        .into_iter()
        .map(|token| {
            let router = w.router.clone();
            tokio::spawn(async move {
                let request = Request::builder()
                    .uri(format!("/space/dock/slots/badges?ids={shown}"))
                    .header("authorization", format!("Bearer {token}"))
                    .body(Body::empty())
                    .unwrap();
                router.oneshot(request).await.unwrap().status()
            })
        })
        .collect();
    tokio::time::sleep(Duration::from_millis(60)).await;

    let asked = Instant::now();
    assert_eq!(w.answer("quick").await, "fast");
    let command_wait = asked.elapsed();
    w.hub.publish(Event::MemberJoined(UserId::generate()));
    let published = Instant::now();
    wait_for("the event run", || async {
        (w.event_runs("listener").await == 1).then_some(())
    })
    .await;
    let event_wait = published.elapsed();
    for fill in fills {
        assert!(fill.await.unwrap().is_success());
    }
    let one_run = started.elapsed();
    eprintln!("command {command_wait:?}, event {event_wait:?}, slot run about {one_run:?}");
    assert!(
        command_wait < one_run / 2,
        "a command waited {command_wait:?}"
    );
    assert!(event_wait < one_run / 2, "an event waited {event_wait:?}");
}
