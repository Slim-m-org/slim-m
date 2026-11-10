// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `channels.parent_message_id` had no index until migration 0043, so
//! `open_thread`'s duplicate check scanned the whole channels table per
//! thread open. The query is read out of its own source file, the
//! `canvas_ops/index_plan.rs` technique, so an edit that dodges the index
//! fails here rather than only slowing down.

mod support;

use std::fs;
use std::path::Path;

use sqlx::{Row, SqlitePool};

async fn new_pool(name: &str) -> (SqlitePool, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new(name);
    let config = slimm_server::config::Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..slimm_server::config::Config::default()
    };
    (
        slimm_server::db::connect(&config)
            .await
            .expect("connect + migrate"),
        guard,
    )
}

#[tokio::test]
async fn the_duplicate_thread_check_seeks_the_parent_index() {
    let (pool, _guard) = new_pool("slimm-thread-plan").await;
    let source =
        fs::read_to_string(Path::new(env!("CARGO_MANIFEST_DIR")).join("src/store/threads.rs"))
            .expect("read threads.rs");
    let sql = support::query_literal_containing(&source, "WHERE parent_message_id = ?");

    let explain = format!("EXPLAIN QUERY PLAN {sql}");
    let zero = vec![0u8; 16];
    let rows = sqlx::query(&explain)
        .bind(&zero)
        .fetch_all(&pool)
        .await
        .expect("plan");
    let plan = rows
        .iter()
        .map(|r| r.get::<String, _>("detail"))
        .collect::<Vec<_>>()
        .join("\n");
    assert!(
        plan.contains("channels_parent_message"),
        "the duplicate-thread check must seek the parent index, got:\n{plan}"
    );
    assert!(
        !plan.contains("SCAN channels"),
        "the duplicate-thread check must never scan channels:\n{plan}"
    );
}
