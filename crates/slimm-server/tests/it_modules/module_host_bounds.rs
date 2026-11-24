// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The bounds a module's host calls keep: a reply size cap, an atomic kv swap,
//! a statement turn that gives up inside the run's deadline, chunked purges and
//! a schema read that does not guess.

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use serde_json::json;
use slimm_server::module_runtime::{
    DataBackend, DataError, DataSchema, Outcome, Shape, SqliteData, Statement, purge_member,
    validate_data_schema,
};
use sqlx::{Connection, SqliteConnection};

use crate::support;
use support::TestDirGuard;
use support::data_rig::{Rig, files};
use support::module_world::{Install, kv_request, world};
use support::wasm_fixtures::host_call_loop_wasm;

#[tokio::test(flavor = "multi_thread")]
async fn a_data_result_past_the_reply_cap_is_refused() {
    let (dir, _g) = TestDirGuard::new("slimm-data-reply-cap");
    let columns: Vec<_> = (0..4)
        .map(|i| json!({ "name": format!("c{i}"), "type": "text" }))
        .collect();
    let schema = json!({ "max_mb": 8, "tables": [{ "name": "t", "columns": columns }] });
    let mut rig = Rig::new(&dir, "big", schema).await;
    let cell = "x".repeat(4000);
    for _ in 0..80 {
        rig.ok(json!({ "op": "insert", "table": "t",
            "values": { "c0": cell, "c1": cell, "c2": cell, "c3": cell } }));
        rig.renew();
    }

    let error = rig.refused(json!({ "op": "query", "table": "t", "limit": 80 }));
    assert!(error.contains("too large"), "{error}");
    rig.renew();
    let small = rig.ok(json!({ "op": "query", "table": "t", "limit": 5 }));
    assert_eq!(small["rows"].as_array().unwrap().len(), 5);
}

#[tokio::test(flavor = "multi_thread")]
async fn two_concurrent_kv_cas_writers_swap_exactly_once() {
    let w = world("slimm-kv-cas").await;
    w.install(Install {
        id: "keeper",
        wasm: host_call_loop_wasm(&kv_request("get", "k", None), 1),
        declared: &["kv.store"],
        approved_host: &["kv.store"],
    })
    .await;
    let store = w.store.clone();
    store
        .module_kv_set("keeper", "n", "0", 256, 65536)
        .await
        .unwrap();
    let writers: Vec<_> = (0..8)
        .map(|i| {
            let store = store.clone();
            tokio::spawn(async move {
                store
                    .module_kv_cas(("keeper", "n"), Some("0"), &format!("w{i}"), (256, 65536))
                    .await
                    .unwrap()
            })
        })
        .collect();
    let mut swapped = 0;
    for writer in writers {
        swapped += usize::from(writer.await.unwrap());
    }
    assert_eq!(swapped, 1);

    let absent = |key| store.module_kv_cas(("keeper", key), None, "a", (256, 65536));
    assert!(absent("fresh").await.unwrap());
    assert!(
        !absent("fresh").await.unwrap(),
        "a second set-if-absent loses"
    );
    assert!(matches!(
        store
            .module_kv_cas(("keeper", "tiny"), None, "a", (1, 65536))
            .await,
        Err(slimm_server::store::KvSetError::Full)
    ));
}

fn one_int_column() -> DataSchema {
    validate_data_schema(&json!({ "max_mb": 8, "tables": [{ "name": "t", "columns": [
        { "name": "c0", "type": "int" }, { "name": "who", "type": "text", "member": true }] }] }))
    .unwrap()
}

fn counting_to(rows: u64) -> Statement {
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
async fn a_statement_waiting_for_the_turn_gives_up_inside_its_own_budget() {
    let (dir, _g) = TestDirGuard::new("slimm-data-turn");
    let data = Arc::new(files(&dir));
    data.apply_schema("m", &one_int_column()).await.unwrap();
    let long = tokio::task::spawn_blocking({
        let data = Arc::clone(&data);
        move || data.execute("m", &counting_to(500_000_000), Duration::from_millis(1500))
    });
    tokio::time::sleep(Duration::from_millis(200)).await;

    let started = Instant::now();
    let waiting = tokio::task::spawn_blocking({
        let data = Arc::clone(&data);
        move || data.execute("m", &counting_to(1), Duration::from_millis(100))
    })
    .await
    .unwrap();

    assert!(matches!(waiting, Err(DataError::TooSlow)), "{waiting:?}");
    assert!(
        started.elapsed() < Duration::from_millis(900),
        "{:?}",
        started.elapsed()
    );
    let _ = long.await.unwrap();
}

struct Counting {
    inner: SqliteData,
    executed: AtomicUsize,
}

impl DataBackend for Counting {
    fn schema(&self, module_id: &str) -> Result<DataSchema, DataError> {
        self.inner.schema(module_id)
    }

    fn execute(
        &self,
        module_id: &str,
        statement: &Statement,
        budget: Duration,
    ) -> Result<Outcome, DataError> {
        self.executed.fetch_add(1, Ordering::Relaxed);
        self.inner.execute(module_id, statement, budget)
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn a_purge_runs_in_chunks_that_free_the_file_between_them() {
    let (dir, _g) = TestDirGuard::new("slimm-data-purge-chunks");
    let data = files(&dir);
    data.apply_schema("m", &one_int_column()).await.unwrap();
    let mut rig = Rig::attach(&dir, "m", &["data.store"]);
    let mut conn = SqliteConnection::connect(&format!("sqlite://{}/m.db", dir.display()))
        .await
        .unwrap();
    sqlx::query(
        "WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n WHERE x < 1200) \
         INSERT INTO t (c0, who) SELECT x, CASE WHEN x % 6 = 0 THEN 'keep' ELSE 'gone' END FROM n",
    )
    .execute(&mut conn)
    .await
    .unwrap();
    conn.close().await.unwrap();
    let backend = Counting {
        inner: files(&dir),
        executed: AtomicUsize::new(0),
    };

    let removed = tokio::task::block_in_place(|| purge_member(&backend, "m", "gone")).unwrap();

    assert_eq!(removed, 1000);
    assert!(backend.executed.load(Ordering::Relaxed) >= 2);
    let left = rig.ok(json!({ "op": "count", "table": "t" }));
    assert_eq!(left["count"], json!(200));
}

#[tokio::test(flavor = "multi_thread")]
async fn a_failed_schema_read_is_not_taken_for_no_schema() {
    let (dir, _g) = TestDirGuard::new("slimm-data-schema-read");
    let data = files(&dir);
    data.apply_schema("m", &one_int_column()).await.unwrap();
    let mut conn = SqliteConnection::connect(&format!("sqlite://{}/m.db", dir.display()))
        .await
        .unwrap();
    for sql in [
        "DROP TABLE _slim_meta",
        "CREATE VIEW _slim_meta AS SELECT 'schema' AS key, abs(-9223372036854775807 - 1) AS value",
    ] {
        sqlx::query(sql).execute(&mut conn).await.unwrap();
    }
    conn.close().await.unwrap();
    let fresh = files(&dir);

    let seen = tokio::task::block_in_place(|| fresh.schema("m"));
    assert!(matches!(seen, Err(DataError::Unavailable)), "{seen:?}");
    let applied = fresh.apply_schema("m", &one_int_column()).await;
    assert!(
        applied.as_ref().is_err_and(|e| e.contains("read")),
        "{applied:?}"
    );
}
