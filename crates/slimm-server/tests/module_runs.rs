// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What the host tells a module and the admin about its runs: the wall clock
//! in the request, the recorded outcomes, and the stored-data usage and reset.

use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::http::run_scheduled_modules;
use slimm_server::permissions::Permissions;
use slimm_server::store::ModuleSchedule;
use tower::ServiceExt;

mod support;
use support::module_world::{Install, World, kv_request, world};
use support::wasm_fixtures::{echo_request_wasm, fuel_burner_wasm, host_call_loop_wasm};

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

async fn call(w: &World, method: &str, uri: &str, token: &str) -> (StatusCode, Value) {
    let request = Request::builder()
        .method(method)
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap();
    let response = w.router.clone().oneshot(request).await.unwrap();
    let status = response.status();
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    (
        status,
        serde_json::from_slice(&bytes).unwrap_or(Value::Null),
    )
}

async fn installed(w: &World, token: &str, id: &str) -> Value {
    let (status, list) = call(w, "GET", "/space/dock/installed", token).await;
    assert_eq!(status, StatusCode::OK);
    list.as_array()
        .unwrap()
        .iter()
        .find(|m| m["id"] == json!(id))
        .cloned()
        .unwrap_or_else(|| panic!("{id} is not installed: {list}"))
}

#[tokio::test]
async fn the_request_carries_the_hosts_wall_clock() {
    let w = world("slimm-modrun-clock").await;
    w.install(Install {
        id: "clock",
        wasm: echo_request_wasm(),
        declared: &[],
        approved_host: &[],
    })
    .await;
    let before = epoch_ms();
    let echoed = w.answer("clock").await;
    let after = epoch_ms();
    let start = echoed.find("'now_ms':").expect("now_ms in the request") + "'now_ms':".len();
    let digits: String = echoed[start..]
        .chars()
        .take_while(char::is_ascii_digit)
        .collect();
    let seen: i64 = digits.parse().unwrap();
    assert!(
        (before..=after).contains(&seen),
        "{seen} not within [{before}, {after}]"
    );
}

fn epoch_ms() -> i64 {
    let since = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap();
    i64::try_from(since.as_millis()).unwrap()
}

#[tokio::test]
async fn an_interactive_failure_is_counted_and_a_later_success_clears_the_streak() {
    let w = world("slimm-modrun-stats").await;
    let token = admin_token(&w).await;
    w.install(Install {
        id: "burner",
        wasm: fuel_burner_wasm(),
        declared: &[],
        approved_host: &[],
    })
    .await;
    w.answer("burner").await;
    w.answer("burner").await;
    let stat = installed(&w, &token, "burner").await["run_stats"][0].clone();
    assert_eq!(stat["command"], json!("run"));
    assert_eq!(stat["run_count"], json!(2));
    assert_eq!(stat["failure_count"], json!(2));
    assert!(stat["failing_since"].is_i64(), "{stat}");
    assert!(
        stat["last_error"].as_str().unwrap().contains("limits"),
        "{stat}"
    );

    w.install(Install {
        id: "burner",
        wasm: echo_request_wasm(),
        declared: &[],
        approved_host: &[],
    })
    .await;
    w.answer("burner").await;
    let stat = installed(&w, &token, "burner").await["run_stats"][0].clone();
    assert_eq!(stat["run_count"], json!(3));
    assert_eq!(stat["failure_count"], json!(2));
    assert!(stat.get("failing_since").is_none(), "{stat}");
    assert!(stat["last_ok_at"].is_i64());
}

#[tokio::test]
async fn a_failed_scheduled_run_shows_its_error_and_uninstall_clears_the_rows() {
    let w = world("slimm-modrun-scheduled").await;
    let token = admin_token(&w).await;
    let feed = w.store.create_channel("feed", "text").await.unwrap();
    w.install(Install {
        id: "ticker",
        wasm: host_call_loop_wasm(
            r#"{"capability":"net.fetch","url":"https://nope.example/"}"#,
            1,
        ),
        declared: &["schedule", "net.fetch"],
        approved_host: &["schedule", "net.fetch"],
    })
    .await;
    w.store
        .set_module_schedules(
            "ticker",
            &[ModuleSchedule {
                command: "run".into(),
                every_minutes: 5,
            }],
        )
        .await
        .unwrap();
    w.store.ensure_module_bot("ticker", "Ticker").await.unwrap();
    w.store
        .set_module_schedule_channel("ticker", Some(feed.id))
        .await
        .unwrap();
    assert_eq!(run_scheduled_modules(&w.state, 0).await.unwrap(), 1);

    let stat = installed(&w, &token, "ticker").await["run_stats"][0].clone();
    assert_eq!(
        stat["failure_count"],
        json!(0),
        "the module answered: {stat}"
    );

    w.install(Install {
        id: "ticker",
        wasm: fuel_burner_wasm(),
        declared: &["schedule"],
        approved_host: &["schedule"],
    })
    .await;
    assert_eq!(
        run_scheduled_modules(&w.state, 5 * 60_000).await.unwrap(),
        1
    );
    let stat = installed(&w, &token, "ticker").await["run_stats"][0].clone();
    assert_eq!(stat["failure_count"], json!(1), "{stat}");
    assert!(
        stat["last_error"].as_str().unwrap().contains("limits"),
        "{stat}"
    );

    let (status, _) = call(&w, "DELETE", "/space/dock/modules/ticker/install", &token).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert!(w.store.module_run_stats().await.unwrap().is_empty());
}

#[tokio::test]
async fn stored_data_usage_is_shown_and_clearing_it_keeps_the_install() {
    let w = world("slimm-modrun-storage").await;
    let token = admin_token(&w).await;
    w.install(Install {
        id: "keeper",
        wasm: host_call_loop_wasm(&kv_request("set", "k@@", Some("value")), 3),
        declared: &["kv.store"],
        approved_host: &["kv.store"],
    })
    .await;
    w.answer("keeper").await;
    let storage = installed(&w, &token, "keeper").await["storage"].clone();
    assert_eq!(storage["entries"], json!(3));
    assert_eq!(storage["bytes"], json!(3 * ("k00".len() + "value".len())));
    assert_eq!(storage["max_entries"], json!(256));
    assert_eq!(storage["max_bytes"], json!(64 * 1024));

    let (denied, _) = call(&w, "DELETE", "/space/dock/modules/keeper/storage", &w.token).await;
    assert_eq!(denied, StatusCode::FORBIDDEN);
    let (status, _) = call(&w, "DELETE", "/space/dock/modules/keeper/storage", &token).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let after = installed(&w, &token, "keeper").await;
    assert_eq!(after["storage"]["entries"], json!(0));
    assert_eq!(after["approved_host_capabilities"], json!(["kv.store"]));

    let (missing, _) = call(&w, "DELETE", "/space/dock/modules/nothing/storage", &token).await;
    assert_eq!(missing, StatusCode::NOT_FOUND);
}
