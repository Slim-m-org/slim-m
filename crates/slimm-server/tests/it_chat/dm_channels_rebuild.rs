// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Migration 0025 against real data: widening `dm_channels`' pair ordering
//! to admit a self pair must not disturb an ordinary pair already stored.
//!
//! 0025's own guard table refuses a discrepancy from inside the transaction,
//! so a failure there is a rollback rather than damage - but every other test
//! database starts empty and never exercises that path at all, unlike the
//! live deployment's upgrade. This seeds a database at 0024 with the pair
//! shape every such deployment actually holds (`user_a < user_b`, the only
//! ordering 0024 and earlier ever accepted) and checks it from outside,
//! mirroring `messages_rowid_alias.rs`'s treatment of 0024.

use std::path::Path;
use std::time::Duration;

use sqlx::migrate::Migrator;
use sqlx::sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions};
use sqlx::{Row, SqlitePool};

use crate::support;
/// The migration under test. Everything before it is the starting point.
const VERSION: i64 = 25;

async fn migrator() -> Migrator {
    Migrator::new(Path::new("./migrations"))
        .await
        .expect("resolve migrations")
}

async fn pool_at_0024() -> (SqlitePool, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::empty("slimm-dm-channels-rebuild");
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
        "0025 is missing from ./migrations"
    );
    before.migrations = before
        .iter()
        .filter(|m| m.version < VERSION)
        .cloned()
        .collect();
    before.run(&pool).await.expect("migrate to 0024");
    (pool, guard)
}

/// Two users and the ordinary DM pair between them, in the only shape 0024
/// and earlier ever accepted.
async fn seed(pool: &SqlitePool) {
    let statements = [
        "INSERT INTO users (id, username, display_name, password_hash, created_at) VALUES
         (x'01010101010101010101010101010101', 'alice', 'Alice', 'hash', 1),
         (x'02020202020202020202020202020202', 'bob', 'Bob', 'hash', 2)",
        "INSERT INTO channels (id, kind, name, position, created_at) VALUES
         (x'11111111111111111111111111111111', 'dm', '', 0, 1)",
        "INSERT INTO dm_channels (channel_id, user_a, user_b, created_at) VALUES
         (x'11111111111111111111111111111111',
          x'01010101010101010101010101010101',
          x'02020202020202020202020202020202', 5)",
    ];
    for statement in statements {
        sqlx::query(statement)
            .execute(pool)
            .await
            .unwrap_or_else(|e| panic!("seeding failed on {statement}: {e}"));
    }
}

/// Every `dm_channels` row, as comparable text.
async fn pairs(pool: &SqlitePool) -> Vec<(String, String, String, i64)> {
    sqlx::query(
        "SELECT hex(channel_id), hex(user_a), hex(user_b), created_at
         FROM dm_channels ORDER BY channel_id",
    )
    .fetch_all(pool)
    .await
    .expect("read dm_channels")
    .iter()
    .map(|row| {
        (
            row.get::<String, _>(0),
            row.get::<String, _>(1),
            row.get::<String, _>(2),
            row.get::<i64, _>(3),
        )
    })
    .collect()
}

async fn count(pool: &SqlitePool, table: &str) -> i64 {
    sqlx::query_scalar(&format!("SELECT count(*) FROM {table}"))
        .fetch_one(pool)
        .await
        .unwrap_or_else(|e| panic!("counting {table}: {e}"))
}

#[tokio::test]
async fn the_rebuild_keeps_an_existing_pair_unchanged() {
    let (pool, _guard) = pool_at_0024().await;
    seed(&pool).await;
    let before = pairs(&pool).await;

    migrator().await.run(&pool).await.expect("apply 0025");

    assert_eq!(
        pairs(&pool).await,
        before,
        "an ordinary pair stored under the old CHECK must survive the rebuild"
    );

    let violations = sqlx::query("PRAGMA foreign_key_check")
        .fetch_all(&pool)
        .await
        .expect("foreign key check");
    assert!(
        violations.is_empty(),
        "{} dangling references after the rebuild",
        violations.len()
    );

    let pair_index: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM pragma_index_list('dm_channels')
         WHERE name = 'dm_channels_pair' AND \"unique\" = 1",
    )
    .fetch_one(&pool)
    .await
    .expect("index list");
    assert_eq!(pair_index, 1, "dm_channels_pair must survive the rebuild");

    let user_b_index: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM pragma_index_list('dm_channels')
         WHERE name = 'dm_channels_user_b'",
    )
    .fetch_one(&pool)
    .await
    .expect("index list");
    assert_eq!(
        user_b_index, 1,
        "dm_channels_user_b must survive the rebuild"
    );

    let leftovers = count(
        &pool,
        "sqlite_master WHERE name LIKE 'dm\\_channels\\_rebuild%' ESCAPE '\\'",
    )
    .await;
    assert_eq!(leftovers, 0, "holding tables outlived the migration");
}

#[tokio::test]
async fn the_widened_check_now_admits_a_self_pair_beside_the_existing_one() {
    let (pool, _guard) = pool_at_0024().await;
    seed(&pool).await;
    migrator().await.run(&pool).await.expect("apply 0025");

    sqlx::query(
        "INSERT INTO channels (id, kind, name, position, created_at) VALUES
         (x'12121212121212121212121212121212', 'dm', '', 1, 2)",
    )
    .execute(&pool)
    .await
    .expect("insert the self pair's channel");

    sqlx::query(
        "INSERT INTO dm_channels (channel_id, user_a, user_b, created_at) VALUES
         (x'12121212121212121212121212121212',
          x'01010101010101010101010101010101',
          x'01010101010101010101010101010101', 6)",
    )
    .execute(&pool)
    .await
    .expect("a self pair must be admitted once the CHECK is widened");

    assert_eq!(
        count(&pool, "dm_channels").await,
        2,
        "the self pair joins the existing ordinary pair, not replaces it"
    );
}
