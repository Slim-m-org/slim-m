// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Migration 0048 against real data: an upgrading deployment's standing
//! removals and timeouts have to arrive in the log, or it opens by implying
//! that nothing had ever happened.
//!
//! Seeds a database at 0047 (before the log existed) with a removal, two
//! timeouts, and one of each whose moderator is already gone, applies 0048 on
//! top, and reads the result back.
//!
//! Written the way `channel_categories_backfill.rs` tests 0031: the empty-
//! database case is the one a normal test run exercises, and it is not the
//! case that can go wrong. A backfill only has anything to do on a database
//! that was already in use.

use std::path::Path;
use std::time::Duration;

use sqlx::migrate::Migrator;
use sqlx::sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions};
use sqlx::{Row, SqlitePool};

use crate::support;
/// The migration under test. Everything before it is the starting point.
const VERSION: i64 = 48;

/// One backfilled row: action, actor, reason, deadline, and when it happened.
type Carried = (String, Option<Vec<u8>>, Option<String>, Option<i64>, i64);

async fn migrator() -> Migrator {
    Migrator::new(Path::new("./migrations"))
        .await
        .expect("resolve migrations")
}

async fn pool_at_0047() -> (SqlitePool, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::empty("slimm-moderation-backfill");
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
        "0048 is missing from ./migrations"
    );
    before.migrations = before
        .iter()
        .filter(|m| m.version < VERSION)
        .cloned()
        .collect();
    before.run(&pool).await.expect("migrate to 0047");
    (pool, guard)
}

/// A deployment mid-life: one member removed, two timed out, and in each case
/// one whose moderator has since deleted their account, which is the state
/// account deletion leaves behind rather than a hypothetical.
///
/// The removal is timed BETWEEN the two timeouts, and that is load-bearing.
/// `UNION ALL` scans `space_removals` first, so a removal that happened before
/// both timeouts would come out in clock order even with the ordering removed,
/// and the ordering test below could never fail. Timed in the middle, dropping
/// the `ORDER BY` puts 6000 ahead of 5000 and the test bites.
async fn seed(pool: &SqlitePool) {
    let statements = [
        "INSERT INTO users (id, username, display_name, password_hash, created_at) VALUES
         (x'01010101010101010101010101010101', 'ada', 'Ada', 'hash', 1),
         (x'02020202020202020202020202020202', 'bram', 'Bram', 'hash', 1),
         (x'03030303030303030303030303030303', 'nia', 'Nia', 'hash', 1),
         (x'04040404040404040404040404040404', 'kit', 'Kit', 'hash', 1),
         (x'05050505050505050505050505050505', 'rae', 'Rae', 'hash', 1)",
        "INSERT INTO member_timeouts (user_id, until, reason, issued_by, issued_at) VALUES
         (x'04040404040404040404040404040404', 9999, 'shouting',
          x'01010101010101010101010101010101', 5000)",
        "INSERT INTO space_removals (user_id, reason, removed_by, removed_at) VALUES
         (x'03030303030303030303030303030303', 'spam',
          x'02020202020202020202020202020202', 6000)",
        "INSERT INTO member_timeouts (user_id, until, reason, issued_by, issued_at) VALUES
         (x'05050505050505050505050505050505', 8888, NULL, NULL, 7000)",
    ];
    for statement in statements {
        sqlx::query(statement)
            .execute(pool)
            .await
            .unwrap_or_else(|e| panic!("seeding failed on {statement}: {e}"));
    }
}

#[tokio::test]
async fn the_backfill_carries_every_standing_act_in_the_order_it_happened() {
    let (pool, _guard) = pool_at_0047().await;
    seed(&pool).await;

    migrator().await.run(&pool).await.expect("apply 0048");

    let rows = sqlx::query(
        "SELECT action, actor_id, subject_id, reason, until, created_at
         FROM moderation_audit_log ORDER BY id",
    )
    .fetch_all(&pool)
    .await
    .expect("read the backfilled log");

    let seen: Vec<Carried> = rows
        .iter()
        .map(|r| {
            (
                r.get("action"),
                r.get("actor_id"),
                r.get("reason"),
                r.get("until"),
                r.get("created_at"),
            )
        })
        .collect();

    assert_eq!(
        seen,
        vec![
            (
                "timeout".to_owned(),
                Some(vec![0x01; 16]),
                Some("shouting".to_owned()),
                Some(9999),
                5000
            ),
            (
                "remove".to_owned(),
                Some(vec![0x02; 16]),
                Some("spam".to_owned()),
                None,
                6000
            ),
            ("timeout".to_owned(), None, None, Some(8888), 7000),
        ],
        "every standing act, oldest first, with its actor and reason intact"
    );
}

/// Asserted on its own, and not folded into the vector comparison above, so
/// that a union which filed every removal before every timeout fails with a
/// message naming the clock rather than as a confusing whole-vector mismatch.
///
/// This test was vacuous when first written, which is worth leaving recorded.
/// The seed had the removal happening before both timeouts, so the unordered
/// union - `space_removals` scanned first - came out in clock order anyway and
/// dropping the `ORDER BY` from the migration changed nothing. Moving the
/// removal between the two timeouts is what gives it teeth.
#[tokio::test]
async fn the_backfill_interleaves_the_two_tables_by_time() {
    let (pool, _guard) = pool_at_0047().await;
    seed(&pool).await;

    migrator().await.run(&pool).await.expect("apply 0048");

    let times: Vec<i64> =
        sqlx::query_scalar("SELECT created_at FROM moderation_audit_log ORDER BY id")
            .fetch_all(&pool)
            .await
            .expect("read the backfilled order");

    let mut sorted = times.clone();
    sorted.sort_unstable();
    assert_eq!(
        times, sorted,
        "id order must agree with the clock across both source tables"
    );
}

/// The live tables are the source of the backfill and must be left exactly as
/// they were: this migration adds history, it does not move it.
#[tokio::test]
async fn the_backfill_leaves_the_tables_it_read_alone() {
    let (pool, _guard) = pool_at_0047().await;
    seed(&pool).await;

    migrator().await.run(&pool).await.expect("apply 0048");

    let removals: i64 = sqlx::query_scalar("SELECT count(*) FROM space_removals")
        .fetch_one(&pool)
        .await
        .unwrap();
    let timeouts: i64 = sqlx::query_scalar("SELECT count(*) FROM member_timeouts")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!((removals, timeouts), (1, 2), "still in force, still there");
}

/// A fresh deployment has nothing to carry over, and must not be given a row
/// implying somebody was moderated before the Space existed.
#[tokio::test]
async fn the_backfill_writes_nothing_on_an_empty_deployment() {
    let (pool, _guard) = pool_at_0047().await;

    migrator().await.run(&pool).await.expect("apply 0048");

    let carried: i64 = sqlx::query_scalar("SELECT count(*) FROM moderation_audit_log")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(carried, 0);
}
