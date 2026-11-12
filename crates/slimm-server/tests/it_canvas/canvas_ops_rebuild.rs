// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Migration 0026 against real data: the guard must abort the rebuild by
//! name rather than dropping whatever a deployment happened to have written
//! to the 0002 shape of `canvas_ops`, even though no deployment ever has (see
//! the migration's own header comment). Mirrors `dm_channels_rebuild.rs`'s
//! treatment of 0025's own guard.

use std::path::Path;
use std::time::Duration;

use sqlx::SqlitePool;
use sqlx::migrate::Migrator;
use sqlx::sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions};

use crate::support;
/// The migration under test. Everything before it is the starting point.
const VERSION: i64 = 26;

async fn migrator() -> Migrator {
    Migrator::new(Path::new("./migrations"))
        .await
        .expect("resolve migrations")
}

async fn pool_at_0025() -> (SqlitePool, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::empty("slimm-canvas-ops-rebuild");
    let options = SqliteConnectOptions::new()
        .filename(&path)
        .create_if_missing(true)
        .journal_mode(SqliteJournalMode::Wal)
        .busy_timeout(Duration::from_secs(5))
        .foreign_keys(true);
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect_with(options)
        .await
        .expect("open pool");

    let mut before = migrator().await;
    assert!(
        before.iter().any(|m| m.version == VERSION),
        "0026 is missing from ./migrations"
    );
    before.migrations = before
        .iter()
        .filter(|m| m.version < VERSION)
        .cloned()
        .collect();
    before.run(&pool).await.expect("migrate to 0025");
    (pool, guard)
}

#[tokio::test]
async fn the_rebuild_proceeds_over_an_empty_table() {
    let (pool, _guard) = pool_at_0025().await;

    migrator()
        .await
        .run(&pool)
        .await
        .expect("0026 must apply cleanly over an empty canvas_ops");

    let live: i64 = sqlx::query_scalar("SELECT count(*) FROM canvas_ops")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(live, 0);

    let leftovers: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM sqlite_master
         WHERE name LIKE 'canvas\\_ops\\_rebuild\\_guard%' ESCAPE '\\'",
    )
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(
        leftovers, 0,
        "the guard table must not outlive the migration"
    );
}

/// The guard aborts by name on a non-empty table. Deleting the guard table
/// from the migration is the mutation this must fail against.
#[tokio::test]
async fn the_rebuild_aborts_by_name_on_a_non_empty_table() {
    let (pool, _guard) = pool_at_0025().await;

    sqlx::query(
        "INSERT INTO channels (id, name, kind, position, created_at) VALUES
         (x'11111111111111111111111111111111', 'general', 'text', 0, 0)",
    )
    .execute(&pool)
    .await
    .expect("seed a channel");
    sqlx::query(
        "INSERT INTO canvas_ops (id, channel_id, seq, author_id, op, created_at) VALUES
         (randomblob(16), x'11111111111111111111111111111111', 1, NULL, '{}', 0)",
    )
    .execute(&pool)
    .await
    .expect("seed a 0002-shape canvas_ops row");

    let outcome = migrator().await.run(&pool).await;
    let error = outcome.expect_err("the rebuild must refuse a non-empty canvas_ops");
    assert!(
        error.to_string().contains("canvas_ops_was_not_empty"),
        "the refusal must name its own guard rather than surface as an opaque failure: {error}"
    );

    let untouched: i64 = sqlx::query_scalar("SELECT count(*) FROM canvas_ops")
        .fetch_one(&pool)
        .await
        .expect("the original table must survive an aborted migration");
    assert_eq!(
        untouched, 1,
        "the aborted rebuild must not have dropped the row"
    );
}
