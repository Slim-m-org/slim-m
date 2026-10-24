// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A `data.store` statement is interrupted at its time budget (decision 0091),
//! and the shape limits that bound its cost are enforced.

use std::path::Path;
use std::time::{Duration, Instant};

use serde_json::{Value, json};
use sqlx::Connection;
use sqlx::sqlite::SqliteConnection;

mod support;
use support::TestDirGuard;
use support::data_rig::{Rig, xp_schema};

async fn seed(dir: &Path, id: &str, rows: u32) {
    let url = format!("sqlite://{}", dir.join(format!("{id}.db")).display());
    let mut conn = SqliteConnection::connect(&url).await.unwrap();
    let sql = format!(
        "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM c WHERE x<{rows}) \
         INSERT INTO xp (user_id, points, ratio, active) \
         SELECT 'user-' || x || '-' || hex(randomblob(64)), x, 0.5, 1 FROM c"
    );
    sqlx::query(&sql).execute(&mut conn).await.unwrap();
}

fn slow_query() -> Value {
    let like = |p: &str| json!({ "col": "user_id", "op": "like", "val": p });
    json!({ "capability": "data.store", "op": "query", "table": "xp",
        "where": [like("%a%b%c%d%"), like("%e%f%1%2%"), like("%3%4%5%6%")],
        "order": [{ "col": "user_id", "dir": "desc" }, { "col": "ratio" }],
        "offset": 10000 })
}

#[tokio::test(flavor = "multi_thread")]
async fn a_statement_past_its_budget_is_interrupted_cleanly() {
    let (dir, _g) = TestDirGuard::new("slimm-data-budget");
    let mut r = Rig::new(&dir, "game", xp_schema()).await;
    seed(&dir, "game", 150_000).await;
    let started = Instant::now();
    let reply = r.raw_before(&slow_query(), Instant::now() + Duration::from_millis(5));
    assert_eq!(
        reply,
        json!({ "ok": false, "error": "data call took too long" })
    );
    assert!(
        started.elapsed() < Duration::from_secs(2),
        "{:?}",
        started.elapsed()
    );
    // The connection is usable again once the interrupt fired.
    let after = r.ok(json!({ "op": "count", "table": "xp" }));
    assert_eq!(after["count"], json!(150_000));
}

#[tokio::test(flavor = "multi_thread")]
async fn a_spent_wall_clock_refuses_the_call() {
    let (dir, _g) = TestDirGuard::new("slimm-data-spent");
    let mut r = Rig::new(&dir, "game", xp_schema()).await;
    let reply = r.raw_before(
        &json!({ "capability": "data.store", "op": "count", "table": "xp" }),
        Instant::now(),
    );
    assert_eq!(reply["error"], json!("data call took too long"));
}

#[tokio::test(flavor = "multi_thread")]
async fn offset_and_like_limits_are_enforced() {
    let (dir, _g) = TestDirGuard::new("slimm-data-shape");
    let mut r = Rig::new(&dir, "game", xp_schema()).await;
    r.ok(json!({ "op": "query", "table": "xp", "offset": 10_000 }));
    r.refused(json!({ "op": "query", "table": "xp", "offset": 10_001 }));
    let like = |n: usize| json!({ "col": "user_id", "op": "like", "val": "a".repeat(n) });
    r.ok(json!({ "op": "query", "table": "xp", "where": [like(256)] }));
    r.refused(json!({ "op": "query", "table": "xp", "where": [like(257)] }));
    let five = vec![like(256); 5];
    r.refused(json!({ "op": "query", "table": "xp", "where": five }));
    let four = vec![like(256); 4];
    r.ok(json!({ "op": "query", "table": "xp", "where": four }));
}
