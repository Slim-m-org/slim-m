// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Migration 0095 against an owner's real data: a database that already holds
//! usernames differing only by case must still migrate.
//!
//! Decided: nobody is deleted or merged. The earliest account of a colliding
//! group keeps its name and every later one is renamed with a short id suffix,
//! recorded in `username_collision_renames`. Everything else about every row
//! must come through untouched.

use std::path::Path;
use std::time::Duration;

use sqlx::migrate::Migrator;
use sqlx::sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions};
use sqlx::{Row, SqlitePool};

use crate::support;
const VERSION: i64 = 95;

type UserRow = (Vec<u8>, String, String, Option<String>, i64, Option<i64>);

async fn pool_at_0094() -> (SqlitePool, Migrator, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::empty("slimm-username-collision");
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
    assert!(full.iter().any(|m| m.version == VERSION), "0095 is missing");
    let mut before = Migrator::new(Path::new("./migrations")).await.unwrap();
    before.migrations = full
        .iter()
        .filter(|m| m.version < VERSION)
        .cloned()
        .collect();
    before.run(&pool).await.unwrap();
    (pool, full, guard)
}

fn id(n: u8) -> String {
    format!("x'{}'", format!("{n:02x}").repeat(16))
}

async fn seed(pool: &SqlitePool) {
    let long = "L".repeat(32);
    let long_other_case = "l".repeat(32);
    let statements = [
        // alice / Alice / ALICE collide; bob is unique; the long pair checks truncation.
        format!(
            "INSERT INTO users (id, username, display_name, password_hash, created_at, deleted_at) VALUES
             ({a1}, 'alice', 'Alice One', 'h1', 100, NULL),
             ({a2}, 'Alice', 'Alice Two', 'h2', 200, NULL),
             ({a3}, 'ALICE', 'Alice Three', 'h3', 300, NULL),
             ({b}, 'bob', 'Bob', 'h4', 150, NULL),
             ({l1}, '{long}', 'Long One', 'h5', 120, NULL),
             ({l2}, '{long_other_case}', 'Long Two', 'h6', 220, NULL),
             ({gone}, 'Alice', 'Deleted', NULL, 50, 400)",
            a1 = id(1),
            a2 = id(2),
            a3 = id(3),
            b = id(4),
            l1 = id(5),
            l2 = id(6),
            gone = id(7),
        ),
    ];
    for statement in statements {
        sqlx::query(&statement).execute(pool).await.unwrap();
    }
}

async fn users(pool: &SqlitePool) -> Vec<UserRow> {
    sqlx::query_as(
        "SELECT id, username, display_name, password_hash, created_at, deleted_at
         FROM users ORDER BY id",
    )
    .fetch_all(pool)
    .await
    .unwrap()
}

async fn user_indexes(pool: &SqlitePool) -> Vec<String> {
    sqlx::query(
        "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'users' ORDER BY name",
    )
    .fetch_all(pool)
    .await
    .unwrap()
    .iter()
    .map(|row| row.get::<String, _>("name"))
    .collect()
}

#[tokio::test]
async fn a_database_with_colliding_usernames_migrates_and_keeps_every_row() {
    let (pool, full, _guard) = pool_at_0094().await;
    seed(&pool).await;
    let rows_before = users(&pool).await;
    let indexes_before = user_indexes(&pool).await;

    full.run(&pool)
        .await
        .expect("0095 must not fail on colliding data");

    let rows_after = users(&pool).await;
    assert_eq!(rows_before.len(), rows_after.len(), "no account is dropped");
    let mut renamed = Vec::new();
    for (before, after) in rows_before.iter().zip(&rows_after) {
        assert_eq!(before.0, after.0);
        assert_eq!(
            (&before.2, &before.3, before.4, before.5),
            (&after.2, &after.3, after.4, after.5)
        );
        if before.1 != after.1 {
            renamed.push((before.1.clone(), after.1.clone(), before.0[0]));
        }
    }
    renamed.sort_by_key(|entry| entry.2);
    assert_eq!(
        renamed
            .iter()
            .map(|(old, _, n)| (old.as_str(), *n))
            .collect::<Vec<_>>(),
        vec![("Alice", 2), ("ALICE", 3), (&"l".repeat(32), 6)],
        "with no activity the earliest of each group keeps its name; the deleted row is left alone"
    );
    assert_eq!(renamed[0].1, "Alice_02020202");
    assert_eq!(renamed[2].1, format!("{}_06060606", "l".repeat(23)));
    assert!(renamed.iter().all(|(_, new, _)| new.chars().count() <= 32));

    let mut lowered: Vec<String> = rows_after
        .iter()
        .filter(|row| row.5.is_none())
        .map(|row| row.1.to_lowercase())
        .collect();
    lowered.sort();
    lowered.dedup();
    assert_eq!(
        lowered.len(),
        rows_after.iter().filter(|r| r.5.is_none()).count()
    );

    let records: Vec<(String, String)> = sqlx::query_as(
        "SELECT old_username, new_username FROM username_collision_renames ORDER BY new_username",
    )
    .fetch_all(&pool)
    .await
    .unwrap();
    assert_eq!(records.len(), 3);

    let indexes_after = user_indexes(&pool).await;
    for name in &indexes_before {
        assert!(indexes_after.contains(name), "index {name} was lost");
    }
    assert_eq!(
        indexes_after.len(),
        indexes_before.len() + 1,
        "exactly the case-insensitive index is new: {indexes_after:?}"
    );
    assert!(indexes_after.contains(&"users_username_lower_live".to_owned()));

    let clash = sqlx::query(
        "INSERT INTO users (id, username, display_name, password_hash, created_at)
         VALUES (x'09090909090909090909090909090909', 'BOB', 'x', 'h', 1)",
    )
    .execute(&pool)
    .await;
    assert!(clash.is_err(), "the new index must refuse a case variant");
}

#[tokio::test]
async fn a_database_without_collisions_migrates_unchanged() {
    let (pool, full, _guard) = pool_at_0094().await;
    sqlx::query(&format!(
        "INSERT INTO users (id, username, display_name, password_hash, created_at)
         VALUES ({}, 'alice', 'Alice', 'h', 1), ({}, 'bob', 'Bob', 'h', 2)",
        id(1),
        id(2)
    ))
    .execute(&pool)
    .await
    .unwrap();
    let before = users(&pool).await;
    full.run(&pool).await.unwrap();
    assert_eq!(before, users(&pool).await);
    let renames: i64 = sqlx::query_scalar("SELECT count(*) FROM username_collision_renames")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(renames, 0);
}

async fn username_of(pool: &SqlitePool, n: u8) -> String {
    sqlx::query_scalar(&format!("SELECT username FROM users WHERE id = {}", id(n)))
        .fetch_one(pool)
        .await
        .unwrap()
}

/// The name stays with the account in use, not the oldest one: the live
/// deployment's `claude` (dormant, earlier) and `Claude` (live, later).
#[tokio::test]
async fn the_name_stays_with_the_account_that_was_active_most_recently() {
    let (pool, full, _guard) = pool_at_0094().await;
    let statements = [
        format!(
            "INSERT INTO users (id, username, display_name, password_hash, created_at) VALUES
             ({d1}, 'claude', 'Claude', 'h', 100), ({d2}, 'Claude', 'Claude', 'h', 200),
             ({e1}, 'dana', 'Dana', 'h', 100), ({e2}, 'Dana', 'Dana', 'h', 200),
             ({f1}, 'finn', 'Finn', 'h', 100), ({f2}, 'Finn', 'Finn', 'h', 200)",
            d1 = id(0x11),
            d2 = id(0x12),
            e1 = id(0x21),
            e2 = id(0x22),
            f1 = id(0x31),
            f2 = id(0x32),
        ),
        format!(
            "INSERT INTO devices (id, user_id, name, created_at, last_seen_at) VALUES
             ({k1}, {d1}, 'old', 100, 150), ({k2}, {d2}, 'new', 200, 900),
             ({k3}, {e1}, 'a', 100, 500), ({k4}, {e2}, 'b', 200, 900)",
            k1 = id(0x41),
            k2 = id(0x42),
            k3 = id(0x43),
            k4 = id(0x44),
            d1 = id(0x11),
            d2 = id(0x12),
            e1 = id(0x21),
            e2 = id(0x22),
        ),
        // claude: only a revoked session. Claude: a live one. The Dana pair has no session at all.
        format!(
            "INSERT INTO sessions (id, user_id, device_id, created_at, last_used_at, revoked_at) VALUES
             ({s1}, {d1}, {k1}, 100, 5000, 6000), ({s2}, {d2}, {k2}, 200, 300, NULL)",
            s1 = id(0x51),
            s2 = id(0x52),
            d1 = id(0x11),
            d2 = id(0x12),
            k1 = id(0x41),
            k2 = id(0x42),
        ),
    ];
    for statement in statements {
        sqlx::query(&statement).execute(&pool).await.unwrap();
    }

    full.run(&pool).await.unwrap();

    assert_eq!(
        username_of(&pool, 0x12).await,
        "Claude",
        "the live account keeps it"
    );
    assert_eq!(username_of(&pool, 0x11).await, "claude_11111111");
    assert_eq!(
        username_of(&pool, 0x22).await,
        "Dana",
        "latest device activity wins"
    );
    assert_eq!(username_of(&pool, 0x21).await, "dana_21212121");
    assert_eq!(
        username_of(&pool, 0x31).await,
        "finn",
        "no activity: earliest wins"
    );
    assert_eq!(username_of(&pool, 0x32).await, "Finn_32323232");
}
