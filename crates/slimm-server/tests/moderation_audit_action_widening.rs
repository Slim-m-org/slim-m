// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Migration 0049 against real data: widening the audit log's action set is a
//! table rebuild, and a rebuild is where audit rows get lost.
//!
//! SQLite cannot widen a CHECK in place, so 0049 builds the table again and
//! copies the rows across. That is the shape 0034 used, and 0034 records what
//! it cost to get wrong the first time: under `foreign_keys=ON` a `DROP TABLE`
//! fires cascades exactly as a `DELETE` would, and its first version lost every
//! dependent row that way.
//!
//! Nothing references `moderation_audit_log` as a parent, so that specific trap
//! does not reach here - but "the rebuild kept the rows" is not something to
//! take on trust about a table whose whole purpose is remembering what
//! happened. Seeds one of every action 0048 allowed, including a row whose
//! actor is already anonymized, and checks all of it survives with its ids and
//! order intact.

use std::path::Path;
use std::time::Duration;

use sqlx::migrate::Migrator;
use sqlx::sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions};
use sqlx::{Row, SqlitePool};

mod support;

/// The migration under test. Everything before it is the starting point.
const VERSION: i64 = 49;

/// One audit row: action, actor, subject, and when.
type Entry = (String, Option<Vec<u8>>, Vec<u8>, i64);

async fn migrator() -> Migrator {
    Migrator::new(Path::new("./migrations"))
        .await
        .expect("resolve migrations")
}

async fn pool_at_0048() -> (SqlitePool, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::empty("slimm-audit-widening");
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
        "0049 is missing from ./migrations"
    );
    before.migrations = before
        .iter()
        .filter(|m| m.version < VERSION)
        .cloned()
        .collect();
    before.run(&pool).await.expect("migrate to 0048");
    (pool, guard)
}

/// One of every action 0048 allowed, plus the anonymized-actor case account
/// deletion leaves behind.
async fn seed(pool: &SqlitePool) {
    let statements = [
        "INSERT INTO users (id, username, display_name, password_hash, created_at) VALUES
         (x'01010101010101010101010101010101', 'ada', 'Ada', 'hash', 1),
         (x'02020202020202020202020202020202', 'nia', 'Nia', 'hash', 1)",
        "INSERT INTO moderation_audit_log
           (actor_id, subject_id, action, reason, until, created_at) VALUES
         (x'01010101010101010101010101010101', x'02020202020202020202020202020202',
          'remove', 'spam', NULL, 3000),
         (x'01010101010101010101010101010101', x'02020202020202020202020202020202',
          'timeout', 'shouting', 9999, 5000),
         (NULL, x'02020202020202020202020202020202', 'timeout_cleared', NULL, 9999, 7000),
         (x'01010101010101010101010101010101', x'02020202020202020202020202020202',
          'restore', NULL, NULL, 9000)",
    ];
    for statement in statements {
        sqlx::query(statement)
            .execute(pool)
            .await
            .unwrap_or_else(|e| panic!("seeding failed on {statement}: {e}"));
    }
}

async fn entries(pool: &SqlitePool) -> Vec<Entry> {
    sqlx::query(
        "SELECT action, actor_id, subject_id, created_at FROM moderation_audit_log ORDER BY id",
    )
    .fetch_all(pool)
    .await
    .expect("read the audit log")
    .iter()
    .map(|r| {
        (
            r.get("action"),
            r.get("actor_id"),
            r.get("subject_id"),
            r.get("created_at"),
        )
    })
    .collect()
}

#[tokio::test]
async fn the_rebuild_keeps_every_act_it_had_already_recorded() {
    let (pool, _guard) = pool_at_0048().await;
    seed(&pool).await;
    let before = entries(&pool).await;
    assert_eq!(before.len(), 4, "the fixture really recorded four acts");

    migrator().await.run(&pool).await.expect("apply 0049");

    assert_eq!(
        entries(&pool).await,
        before,
        "every act, in the same order, with its actor - including the one already anonymized"
    );
}

#[tokio::test]
async fn the_widened_action_is_accepted_and_the_old_ones_still_constrained() {
    let (pool, _guard) = pool_at_0048().await;
    seed(&pool).await;
    // Through 0049 only: 0118 deliberately opens the action set, which moderation_audit_rebuilds.rs covers.
    let mut through_0049 = migrator().await;
    through_0049.migrations = through_0049
        .iter()
        .filter(|m| m.version <= VERSION)
        .cloned()
        .collect();
    through_0049.run(&pool).await.expect("apply 0049");

    sqlx::query(
        "INSERT INTO moderation_audit_log (actor_id, subject_id, action, created_at)
         VALUES (x'01010101010101010101010101010101', x'02020202020202020202020202020202',
                 'messages_deleted', 11000)",
    )
    .execute(&pool)
    .await
    .expect("the new action must be allowed");

    let bogus = sqlx::query(
        "INSERT INTO moderation_audit_log (actor_id, subject_id, action, created_at)
         VALUES (x'01010101010101010101010101010101', x'02020202020202020202020202020202',
                 'not_an_action', 12000)",
    )
    .execute(&pool)
    .await;
    assert!(bogus.is_err(), "the action set must still be closed");

    let dated = sqlx::query(
        "INSERT INTO moderation_audit_log (actor_id, subject_id, action, until, created_at)
         VALUES (x'01010101010101010101010101010101', x'02020202020202020202020202020202',
                 'messages_deleted', 500, 13000)",
    )
    .execute(&pool)
    .await;
    assert!(
        dated.is_err(),
        "a deadline belongs to a timeout, and the until rule must still say so"
    );
}

/// The rebuild drops the old table's indexes with it. Both have to come back,
/// or account deletion's own actor cleanup silently starts scanning every act
/// ever recorded. Later migrations may add indexes of their own (0068 does),
/// so this checks the two 0049 promises are present, not that they are alone.
#[tokio::test]
async fn the_rebuild_restores_both_indexes() {
    let (pool, _guard) = pool_at_0048().await;
    migrator().await.run(&pool).await.expect("apply 0049");

    let names: Vec<String> = sqlx::query_scalar(
        "SELECT name FROM sqlite_master WHERE type = 'index'
         AND tbl_name = 'moderation_audit_log' AND name NOT LIKE 'sqlite_%' ORDER BY name",
    )
    .fetch_all(&pool)
    .await
    .unwrap();
    for rebuilt in ["moderation_audit_log_actor", "moderation_audit_log_subject"] {
        assert!(
            names.iter().any(|n| n == rebuilt),
            "{rebuilt} must survive the rebuild; the indexes are {names:?}"
        );
    }
}
