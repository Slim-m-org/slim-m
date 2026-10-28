// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The data backfills inside migrations 0125 (a bot's assigned prefix) and
//! 0144 (a canvas clear's affected count), run against rows that existed
//! before them.

use std::path::Path;
use std::time::Duration;

use sqlx::SqlitePool;
use sqlx::migrate::Migrator;
use sqlx::sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions};

mod support;

fn id(n: u8) -> String {
    format!("x'{}'", format!("{n:02x}").repeat(16))
}

/// A database migrated up to, not including, `version`, and the full migrator to finish it with.
async fn pool_before(version: i64) -> (SqlitePool, Migrator, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::empty("slimm-backfill-migration");
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
        .unwrap();
    let full = Migrator::new(Path::new("./migrations")).await.unwrap();
    assert!(
        full.iter().any(|m| m.version == version),
        "{version} is missing"
    );
    let mut before = Migrator::new(Path::new("./migrations")).await.unwrap();
    before.migrations = full
        .iter()
        .filter(|m| m.version < version)
        .cloned()
        .collect();
    before.run(&pool).await.unwrap();
    (pool, full, guard)
}

async fn seed(pool: &SqlitePool, statements: &str) {
    for statement in statements.split(';') {
        sqlx::query(statement).execute(pool).await.unwrap();
    }
}

#[tokio::test]
async fn a_bot_with_a_registration_adopts_its_prefix_and_the_rest_stay_unassigned() {
    let (pool, full, _guard) = pool_before(125).await;
    seed(
        &pool,
        &format!(
            "INSERT INTO users (id, username, display_name, password_hash, created_at, is_bot) VALUES
               ({registered}, 'registered', 'Registered', 'h', 1, 1),
               ({silent}, 'silent', 'Silent', 'h', 1, 1),
               ({human}, 'human', 'Human', 'h', 1, 0);
             INSERT INTO bot_command_registrations (bot_user_id, prefix, updated_at)
               VALUES ({registered}, '!', 1)",
            registered = id(1),
            silent = id(2),
            human = id(3),
        ),
    )
    .await;

    full.run(&pool).await.unwrap();

    let prefixes: Vec<(Vec<u8>, Option<String>)> =
        sqlx::query_as("SELECT id, bot_prefix FROM users ORDER BY id")
            .fetch_all(&pool)
            .await
            .unwrap();
    assert_eq!(
        prefixes,
        vec![
            (vec![1u8; 16], Some("!".to_owned())),
            (vec![2u8; 16], None),
            (vec![3u8; 16], None),
        ]
    );
}

#[tokio::test]
async fn a_clear_keeps_the_count_it_originally_removed() {
    let (pool, full, _guard) = pool_before(144).await;
    let (channel, other) = (id(10), id(11));
    // Five objects; a clear at t=100 bound to seq 3 removed seqs 1 and 2 (seq 3 was already gone at t=50).
    seed(
        &pool,
        &format!(
            "INSERT INTO channels (id, name, kind, position, created_at) VALUES
               ({channel}, 'canvas', 'canvas', 0, 0),
               ({other}, 'other', 'canvas', 1, 0);
             INSERT INTO canvas_objects (id, channel_id, channel_key, kind, seq, created_at, deleted_at) VALUES
               (randomblob(16), {channel}, 1, 'stroke', 1, 1, 100),
               (randomblob(16), {channel}, 1, 'stroke', 2, 2, 100),
               (randomblob(16), {channel}, 1, 'stroke', 3, 3, 50),
               (randomblob(16), {channel}, 1, 'stroke', 4, 4, NULL),
               (randomblob(16), {channel}, 1, 'stroke', 5, 5, 100),
               (randomblob(16), {other}, 2, 'stroke', 1, 1, 100);
             INSERT INTO canvas_ops (channel_id, seq, id, kind, bound_seq, created_at) VALUES
               ({channel}, 1, randomblob(16), 'place', NULL, 1),
               ({channel}, 2, randomblob(16), 'clear', 3, 100),
               ({other}, 1, randomblob(16), 'clear', 1, 100),
               ({other}, 2, randomblob(16), 'clear', 0, 200)",
        ),
    )
    .await;

    full.run(&pool).await.unwrap();

    let rows: Vec<(Vec<u8>, i64, Option<i64>)> =
        sqlx::query_as("SELECT channel_id, seq, affected FROM canvas_ops ORDER BY channel_id, seq")
            .fetch_all(&pool)
            .await
            .unwrap();
    assert_eq!(
        rows,
        vec![
            (vec![10u8; 16], 1, None),
            (vec![10u8; 16], 2, Some(2)),
            (vec![11u8; 16], 1, Some(1)),
            (vec![11u8; 16], 2, Some(0)),
        ]
    );
}

#[tokio::test]
async fn undoing_a_clear_does_not_change_its_stored_count() {
    let (pool, full, _guard) = pool_before(144).await;
    let channel = id(10);
    seed(
        &pool,
        &format!(
            "INSERT INTO channels (id, name, kind, position, created_at) VALUES ({channel}, 'canvas', 'canvas', 0, 0);
             INSERT INTO canvas_objects (id, channel_id, channel_key, kind, seq, created_at, deleted_at) VALUES
               (randomblob(16), {channel}, 1, 'stroke', 1, 1, 100),
               (randomblob(16), {channel}, 1, 'stroke', 2, 2, 100);
             INSERT INTO canvas_ops (channel_id, seq, id, kind, bound_seq, created_at) VALUES
               ({channel}, 1, randomblob(16), 'clear', 2, 100)",
        ),
    )
    .await;
    full.run(&pool).await.unwrap();

    sqlx::query("UPDATE canvas_objects SET deleted_at = NULL")
        .execute(&pool)
        .await
        .unwrap();

    let affected: Option<i64> = sqlx::query_scalar("SELECT affected FROM canvas_ops WHERE seq = 1")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(
        affected,
        Some(2),
        "the count must outlive the fence it was derived from"
    );
}
