// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A module's `run_after` sets a one-shot timer the host runs later as the
//! module's own principal, no sooner than ten seconds, and only with an
//! approved `schedule` capability.

use slimm_server::http::run_module_timers;
use slimm_server::store::TimerSpec;

mod support;
use support::module_world::{Install, World, world};
use support::wasm_fixtures::canned_raw_wasm;

fn now_ms() -> i64 {
    let since = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap();
    i64::try_from(since.as_millis()).unwrap()
}

const ASKS: &[u8] =
    br#"{"ok":true,"output":"ok","run_after":{"command":"run","after_ms":1,"key":"c1"}}"#;
const CANCELS: &[u8] =
    br#"{"ok":true,"output":"ok","run_after":{"command":"run","key":"c1","cancel":true}}"#;

async fn install(w: &World, answer: &[u8], approved: &[&str]) {
    w.install(Install {
        id: "pomo",
        wasm: canned_raw_wasm(answer),
        declared: &["schedule"],
        approved_host: approved,
    })
    .await;
    w.store.ensure_module_bot("pomo", "Pomo").await.unwrap();
}

#[tokio::test]
async fn a_timer_never_fires_sooner_than_ten_seconds_and_then_runs_once() {
    let w = world("slimm-timers-min").await;
    install(&w, ASKS, &["schedule"]).await;
    let before = now_ms();
    w.run_in("pomo", None).await;
    assert_eq!(w.store.pending_module_timers("pomo").await.unwrap(), 1);
    assert_eq!(
        run_module_timers(&w.state, before + 9_000).await.unwrap(),
        0,
        "a 1 ms request is held to the floor"
    );
    assert_eq!(
        run_module_timers(&w.state, now_ms() + 11_000)
            .await
            .unwrap(),
        1
    );
    assert_eq!(
        w.store.pending_module_timers("pomo").await.unwrap(),
        1,
        "the timer run asked again, and that is a new timer"
    );
}

#[tokio::test]
async fn a_module_without_the_schedule_capability_sets_no_timer() {
    let w = world("slimm-timers-unapproved").await;
    install(&w, ASKS, &[]).await;
    w.run_in("pomo", None).await;
    assert_eq!(w.store.pending_module_timers("pomo").await.unwrap(), 0);
}

#[tokio::test]
async fn a_cancel_removes_the_pending_timer() {
    let w = world("slimm-timers-cancel").await;
    install(&w, ASKS, &["schedule"]).await;
    w.run_in("pomo", None).await;
    install(&w, CANCELS, &["schedule"]).await;
    w.run_in("pomo", None).await;
    assert_eq!(w.store.pending_module_timers("pomo").await.unwrap(), 0);
}

#[tokio::test]
async fn a_module_may_have_a_bounded_number_of_timers_waiting() {
    let w = world("slimm-timers-cap").await;
    install(&w, ASKS, &["schedule"]).await;
    let spec = |key: &'static str| TimerSpec {
        command: "run",
        key,
        input: "",
        channel_id: None,
        run_at: 1,
    };
    let keys: Vec<String> = (0..33).map(|n| format!("k{n}")).collect();
    for key in &keys[..32] {
        let key: &'static str = Box::leak(key.clone().into_boxed_str());
        assert!(
            w.store
                .set_module_timer("pomo", &spec(key), 32)
                .await
                .unwrap()
        );
    }
    let over: &'static str = Box::leak(keys[32].clone().into_boxed_str());
    assert!(
        !w.store
            .set_module_timer("pomo", &spec(over), 32)
            .await
            .unwrap()
    );
    assert!(
        w.store
            .set_module_timer("pomo", &spec("k0"), 32)
            .await
            .unwrap(),
        "asking again for a key it already has replaces it"
    );
}

fn spec<'a>(key: &'a str, input: &'a str, run_at: i64) -> TimerSpec<'a> {
    TimerSpec {
        command: "run",
        key,
        input,
        channel_id: None,
        run_at,
    }
}

#[tokio::test]
async fn an_error_part_way_through_a_sweep_leaves_the_rest_of_the_batch_stored() {
    use sqlx::{Connection, Executor};
    let w = world("slimm-timers-midbatch").await;
    install(&w, ASKS, &["schedule"]).await;
    w.install(Install {
        id: "broken",
        wasm: canned_raw_wasm(ASKS),
        declared: &["schedule"],
        approved_host: &["schedule"],
    })
    .await;
    let store = &w.store;
    store
        .set_module_timer("broken", &spec("a", "", 1), 32)
        .await
        .unwrap();
    store
        .set_module_timer("pomo", &spec("b", "", 2), 32)
        .await
        .unwrap();
    store
        .set_module_timer("pomo", &spec("c", "", 3), 32)
        .await
        .unwrap();
    let mut conn = sqlx::SqliteConnection::connect(&format!("sqlite://{}", w.db_path))
        .await
        .unwrap();
    conn.execute("PRAGMA foreign_keys = OFF").await.unwrap();
    conn.execute("UPDATE installed_modules SET bot_user_id = x'01' WHERE id = 'broken'")
        .await
        .unwrap();

    assert!(run_module_timers(&w.state, 10).await.is_err());

    assert_eq!(
        store.pending_module_timers("pomo").await.unwrap(),
        2,
        "the timers after the failing one were never claimed"
    );
    assert_eq!(
        store.pending_module_timers("broken").await.unwrap(),
        1,
        "the one that hit the error is put back"
    );
}

#[tokio::test]
async fn a_claim_leaves_a_timer_the_module_has_since_moved_later() {
    let w = world("slimm-timers-claim-moved").await;
    install(&w, ASKS, &["schedule"]).await;
    w.store
        .set_module_timer("pomo", &spec("k", "first", 5), 32)
        .await
        .unwrap();
    let listed = w.store.due_module_timers(10, 16).await.unwrap();
    assert_eq!(listed.len(), 1);

    w.store
        .set_module_timer("pomo", &spec("k", "later", 500), 32)
        .await
        .unwrap();

    assert!(
        w.store
            .claim_module_timer(&listed[0], 10)
            .await
            .unwrap()
            .is_none()
    );
    assert_eq!(w.store.pending_module_timers("pomo").await.unwrap(), 1);
}

#[tokio::test]
async fn putting_a_claimed_timer_back_never_overwrites_a_newer_one() {
    let w = world("slimm-timers-release").await;
    install(&w, ASKS, &["schedule"]).await;
    w.store
        .set_module_timer("pomo", &spec("k", "old", 5), 32)
        .await
        .unwrap();
    let listed = w.store.due_module_timers(10, 16).await.unwrap();
    let claimed = w
        .store
        .claim_module_timer(&listed[0], 10)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(claimed.input, "old");
    assert_eq!(w.store.pending_module_timers("pomo").await.unwrap(), 0);

    w.store
        .set_module_timer("pomo", &spec("k", "new", 6), 32)
        .await
        .unwrap();
    w.store.release_module_timer(&claimed).await.unwrap();

    let after = w.store.due_module_timers(10, 16).await.unwrap();
    assert_eq!(after.len(), 1);
    assert_eq!(after[0].input, "new");
}
