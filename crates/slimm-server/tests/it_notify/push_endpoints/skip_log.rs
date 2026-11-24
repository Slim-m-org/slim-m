// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The default-mode log says how many recipients a push left out, never who or on which device.

use serde_json::json;
use slimm_server::logging::{FileLimits, LogMode, LogSettings, Logging, plan_recent, read_plan};
use slimm_server::push::PushSender;
use tower::ServiceExt;

use crate::push_endpoints::harness::{
    SHORT_DEBOUNCE_MS, app, push_config, register_push, register_user, request, seeded_store,
    spawn_mock_relay, wait_until,
};
use crate::push_endpoints::missed_call::open_dm;
use crate::support;

const SKIPPED: &str = "push: recipients skipped";

/// Runs one message to a foreground-only recipient and returns every log line it wrote.
async fn log_of_a_skipped_message(dm: bool) -> (Vec<String>, String) {
    let (dir, _dir_guard) = support::TestDirGuard::new("slimm-push-skip-log");
    let built = Logging::build(
        &LogSettings {
            base_filter: String::new(),
            dir: Some(dir),
            limits: FileLimits::new(14, 1 << 24),
        },
        false,
    );
    let _guard = tracing::dispatcher::set_default(&built.dispatch);
    built.logging.set_mode(LogMode::Off);

    let (store, channel_id, _db) = seeded_store().await;
    let (mock, relay_url) = spawn_mock_relay().await;
    let push = PushSender::with_debounce_window_ms(&push_config(&relay_url), SHORT_DEBOUNCE_MS)
        .expect("push sender");
    let app = app(store.clone(), push);
    let (alice_token, _) = register_user(&store, "alice").await;
    let (bob_token, bob_id) = register_user(&store, "bob").await;
    register_push(&app, &bob_token, "bobs-token").await;
    let reported = app
        .clone()
        .oneshot(request(
            "PUT",
            "/push/lifecycle",
            Some(&bob_token),
            Some(json!({ "state": "foreground" })),
        ))
        .await
        .unwrap();
    assert_eq!(reported.status(), axum::http::StatusCode::NO_CONTENT);
    let channel = if dm {
        open_dm(&app, &alice_token, &bob_id).await
    } else {
        channel_id.to_string()
    };
    app.clone()
        .oneshot(request(
            "POST",
            &format!("/channels/{channel}/messages"),
            Some(&alice_token),
            Some(json!({ "id": uuid::Uuid::now_v7().to_string(), "content": "hi" })),
        ))
        .await
        .unwrap();
    // Nobody is pushed, so give the background task time to log instead of waiting on the relay.
    wait_until(
        || mock.call_count() > 0,
        std::time::Duration::from_millis(600),
    )
    .await;
    built.logging.flush();
    let plan = plan_recent(
        built.logging.dir().unwrap(),
        1 << 24,
        slimm_server::logging::today(),
    )
    .unwrap();
    let text = String::from_utf8(read_plan(&plan).unwrap()).unwrap();
    (text.lines().map(str::to_owned).collect(), bob_id)
}

#[tokio::test]
async fn the_skip_line_carries_counts_and_no_ids() {
    let (lines, bob_id) = log_of_a_skipped_message(false).await;
    let skipped: Vec<_> = lines.iter().filter(|l| l.contains(SKIPPED)).collect();
    assert_eq!(skipped.len(), 1, "one skip line per message: {lines:?}");
    assert!(skipped[0].contains("foreground_device=1"));
    assert!(
        lines.iter().all(|l| !l.contains(&bob_id)),
        "a user id reached the log"
    );
    assert!(
        lines.iter().all(|l| !l.contains("devices=")),
        "a device list reached the log"
    );
}

#[tokio::test]
async fn a_dm_writes_no_skip_line() {
    let (lines, _) = log_of_a_skipped_message(true).await;
    assert!(lines.iter().all(|l| !l.contains(SKIPPED)), "{lines:?}");
}
