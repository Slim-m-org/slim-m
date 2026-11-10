// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A module's data file under overlapping runs: a migration while a run reads,
//! and two statements on one file sharing one deadline.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use serde_json::json;
use slimm_server::module_runtime::{
    DataBackend, DataError, DataSchema, Shape, Statement, validate_data_schema,
};

mod support;
use support::TestDirGuard;
use support::data_rig::files;

fn wide(columns: usize) -> DataSchema {
    let columns: Vec<_> = (0..columns)
        .map(|i| json!({ "name": format!("c{i}"), "type": "int" }))
        .collect();
    validate_data_schema(&json!({ "max_mb": 8, "tables": [{ "name": "t", "columns": columns }] }))
        .unwrap()
}

#[tokio::test(flavor = "multi_thread")]
async fn a_run_reading_during_a_migration_never_pins_the_old_schema() {
    let (dir, _g) = TestDirGuard::new("slimm-data-migrate-race");
    let data = Arc::new(files(&dir));
    data.apply_schema("scores", &wide(1)).await.unwrap();
    let reading = Arc::new(AtomicBool::new(true));
    let reader = tokio::task::spawn_blocking({
        let (data, reading) = (Arc::clone(&data), Arc::clone(&reading));
        move || {
            while reading.load(Ordering::Relaxed) {
                let _ = data.schema("scores");
            }
        }
    });

    for columns in 2..=8 {
        data.apply_schema("scores", &wide(columns)).await.unwrap();
        let probe = Arc::clone(&data);
        let seen = tokio::task::spawn_blocking(move || probe.schema("scores"))
            .await
            .unwrap()
            .unwrap();
        let seen_columns = seen.tables[0].columns.len();
        if seen != wide(columns) {
            reading.store(false, Ordering::Relaxed);
            panic!("after migrating to {columns} columns the run saw {seen_columns}");
        }
    }
    reading.store(false, Ordering::Relaxed);
    reader.await.unwrap();
}

/// Inserts a row holding how many rows a recursive count walked, which costs time and nothing else.
fn counting_to(rows: u32) -> Statement {
    Statement {
        sql: format!(
            "INSERT INTO \"t\" (\"c0\") SELECT count(*) FROM \
             (WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n WHERE x < {rows}) SELECT x FROM n)"
        ),
        binds: Vec::new(),
        shape: Shape::Insert,
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn overlapping_statements_each_keep_their_own_deadline() {
    let (dir, _g) = TestDirGuard::new("slimm-data-deadlines");
    let data = Arc::new(files(&dir));
    data.apply_schema("scores", &wide(1)).await.unwrap();
    let started = Instant::now();

    let long_budget = tokio::task::spawn_blocking({
        let data = Arc::clone(&data);
        move || data.execute("scores", &counting_to(3_000_000), Duration::from_secs(60))
    });
    tokio::time::sleep(Duration::from_millis(40)).await;
    let short_budget = tokio::task::spawn_blocking({
        let data = Arc::clone(&data);
        move || {
            data.execute(
                "scores",
                &counting_to(20_000_000),
                Duration::from_millis(100),
            )
        }
    });

    let (long, short) = (long_budget.await.unwrap(), short_budget.await.unwrap());
    assert!(
        long.is_ok(),
        "a short deadline set meanwhile must not end it: {long:?}"
    );
    assert!(matches!(short, Err(DataError::TooSlow)), "{short:?}");
    assert!(started.elapsed() < Duration::from_secs(30));
}
