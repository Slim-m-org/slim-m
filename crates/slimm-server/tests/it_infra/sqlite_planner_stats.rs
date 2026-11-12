// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The pool runs `PRAGMA optimize` as a connection closes, so the planner
//! works from statistics instead of guessing on every join. Nothing else in
//! the server ever runs `ANALYZE`; without this a database never has any.

use crate::support;
use slimm_server::config::Config;

async fn open(path: &str) -> sqlx::SqlitePool {
    let config = Config {
        port: 0,
        database_path: path.to_owned(),
        hash_concurrency: 2,
        ..Config::default()
    };
    slimm_server::db::connect(&config)
        .await
        .expect("connect + migrate")
}

async fn stat_tables(pool: &sqlx::SqlitePool) -> i64 {
    sqlx::query_scalar("SELECT COUNT(*) FROM sqlite_master WHERE name = 'sqlite_stat1'")
        .fetch_one(pool)
        .await
        .unwrap()
}

#[tokio::test]
async fn closing_the_pool_leaves_planner_statistics_behind() {
    // Unseeded, because the shared template database is itself closed through this pool.
    let (path, _guard) = support::TestDbGuard::empty("slimm-planner-stats");
    let pool = open(&path).await;
    assert_eq!(
        stat_tables(&pool).await,
        0,
        "a new database starts with statistics"
    );
    sqlx::query("SELECT id FROM messages WHERE channel_id = x'00' AND deleted_at IS NULL ORDER BY seq DESC LIMIT 10")
        .fetch_all(&pool)
        .await
        .unwrap();
    pool.close().await;

    let reopened = open(&path).await;
    assert_eq!(
        stat_tables(&reopened).await,
        1,
        "no connection analyzed anything while closing"
    );
    let rows: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM sqlite_stat1")
        .fetch_one(&reopened)
        .await
        .unwrap();
    assert!(rows > 0, "sqlite_stat1 exists but holds no statistics");
}
