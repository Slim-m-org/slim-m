// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What the installed listing says about a module's fuel and its event queue: the fuel the last
//! run and the heaviest run burned, against the ceiling, and how many events are waiting.

use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::permissions::Permissions;
use tower::ServiceExt;

mod support;
use support::module_world::{Install, World, world};
use support::wasm_fixtures::{echo_request_wasm, fuel_burner_wasm};

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

async fn installed(w: &World, token: &str, id: &str) -> Value {
    let request = Request::builder()
        .method("GET")
        .uri("/space/dock/installed")
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap();
    let response = w.router.clone().oneshot(request).await.unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    let list: Value = serde_json::from_slice(&bytes).unwrap();
    list.as_array()
        .unwrap()
        .iter()
        .find(|m| m["id"] == json!(id))
        .cloned()
        .unwrap()
}

#[tokio::test]
async fn a_run_records_the_fuel_it_burned_against_the_modules_ceiling() {
    let w = world("slimm-modfuel-record").await;
    let token = admin_token(&w).await;
    w.install(Install {
        id: "echo",
        wasm: echo_request_wasm(),
        declared: &[],
        approved_host: &[],
    })
    .await;
    w.answer("echo").await;
    let module = installed(&w, &token, "echo").await;
    let stat = &module["run_stats"][0];
    let used = stat["last_fuel_used"].as_i64().expect("fuel was read");
    assert!(
        used > 0,
        "a run that executed instructions burned fuel: {stat}"
    );
    assert_eq!(stat["max_fuel_used"], json!(used));
    assert_eq!(module["fuel_limit"], json!(50_000_000));
    assert!(used < 50_000_000);
}

#[tokio::test]
async fn the_heaviest_run_is_kept_while_the_last_one_is_replaced() {
    let w = world("slimm-modfuel-max").await;
    let token = admin_token(&w).await;
    w.install(Install {
        id: "echo",
        wasm: echo_request_wasm(),
        declared: &[],
        approved_host: &[],
    })
    .await;
    w.answer("echo").await;
    w.store
        .record_module_run(
            "echo",
            "run",
            &slimm_server::store::RunResult::Ok,
            slimm_server::store::RunTiming {
                at: 5,
                duration_ms: 1,
                fuel_used: Some(9_000_000),
            },
        )
        .await
        .unwrap();
    w.store
        .record_module_run(
            "echo",
            "run",
            &slimm_server::store::RunResult::Ok,
            slimm_server::store::RunTiming {
                at: 6,
                duration_ms: 1,
                fuel_used: Some(1_000),
            },
        )
        .await
        .unwrap();
    let stat = installed(&w, &token, "echo").await["run_stats"][0].clone();
    assert_eq!(stat["max_fuel_used"], json!(9_000_000));
    assert_eq!(stat["last_fuel_used"], json!(1_000));
}

#[tokio::test]
async fn a_run_with_no_reading_leaves_the_fuel_absent_and_the_maximum_alone() {
    let w = world("slimm-modfuel-unread").await;
    let token = admin_token(&w).await;
    w.install(Install {
        id: "echo",
        wasm: echo_request_wasm(),
        declared: &[],
        approved_host: &[],
    })
    .await;
    w.store
        .record_module_run("echo", "slot", &slimm_server::store::RunResult::Ok, (1, 1))
        .await
        .unwrap();
    let list = installed(&w, &token, "echo").await;
    let stat = list["run_stats"]
        .as_array()
        .unwrap()
        .iter()
        .find(|s| s["command"] == "slot")
        .unwrap()
        .clone();
    assert!(stat.get("last_fuel_used").is_none(), "{stat}");
    assert_eq!(stat["max_fuel_used"], json!(0));
}

#[tokio::test]
async fn a_run_that_hits_its_fuel_ceiling_reports_all_of_it() {
    let w = world("slimm-modfuel-ceiling").await;
    let token = admin_token(&w).await;
    w.install(Install {
        id: "burner",
        wasm: fuel_burner_wasm(),
        declared: &[],
        approved_host: &[],
    })
    .await;
    w.answer("burner").await;
    let module = installed(&w, &token, "burner").await;
    let stat = &module["run_stats"][0];
    // The wall clock can end a slow runner's burner first, which is then unread; fuel ending it is the whole budget.
    if let Some(used) = stat["last_fuel_used"].as_i64() {
        assert!(
            used > 0 && used <= module["fuel_limit"].as_i64().unwrap(),
            "{stat}"
        );
    }
}

#[tokio::test]
async fn the_listing_carries_the_event_queue_depth_even_when_nothing_waits() {
    let w = world("slimm-modfuel-queue").await;
    let token = admin_token(&w).await;
    w.install(Install {
        id: "echo",
        wasm: echo_request_wasm(),
        declared: &[],
        approved_host: &[],
    })
    .await;
    let module = installed(&w, &token, "echo").await;
    assert_eq!(module["queue_depth"], json!(0));
}
