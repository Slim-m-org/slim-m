// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Migration 0081 against real data: an account with quiet hours already set
//! must keep exactly the same push behaviour after upgrading to the
//! notification schedule, never a slightly different one.
//!
//! Seeds a database at 0080 (before the schedule table existed) with one
//! user who has quiet hours set and one who does not, applies 0081 on top,
//! and reads the result back - the same technique
//! `moderation_audit_backfill.rs` uses for migration 0048.

use std::path::Path;
use std::time::Duration;

use sqlx::migrate::Migrator;
use sqlx::sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions};
use sqlx::{Row, SqlitePool};

mod support;

/// The migration under test. Everything before it is the starting point.
const VERSION: i64 = 81;

async fn migrator() -> Migrator {
    Migrator::new(Path::new("./migrations"))
        .await
        .expect("resolve migrations")
}

/// Applies 0081 and stops there: later migrations drop the legacy columns
/// these tests read.
async fn apply_0081(pool: &SqlitePool) {
    let mut through = migrator().await;
    through.migrations = through
        .iter()
        .filter(|m| m.version <= VERSION)
        .cloned()
        .collect();
    through.run(pool).await.expect("apply 0081");
}

async fn pool_at_0080() -> (SqlitePool, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::empty("slimm-notif-schedule-backfill");
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
        "0081 is missing from ./migrations"
    );
    before.migrations = before
        .iter()
        .filter(|m| m.version < VERSION)
        .cloned()
        .collect();
    before.run(&pool).await.expect("migrate to 0080");
    (pool, guard)
}

/// A user with quiet hours 15:00-01:40 UTC (900-100, the ordinary
/// midnight-crossing shape) and one with no quiet hours ever set.
async fn seed(pool: &SqlitePool) {
    let statements = [
        "INSERT INTO users
            (id, username, display_name, password_hash, created_at,
             quiet_hours_start_minute, quiet_hours_end_minute)
         VALUES
            (x'01010101010101010101010101010101', 'ada', 'Ada', 'hash', 1, 900, 100)",
        "INSERT INTO users (id, username, display_name, password_hash, created_at)
         VALUES (x'02020202020202020202020202020202', 'bram', 'Bram', 'hash', 1)",
    ];
    for statement in statements {
        sqlx::query(statement)
            .execute(pool)
            .await
            .unwrap_or_else(|e| panic!("seeding failed on {statement}: {e}"));
    }
}

/// Ada's schedule is seeded in UTC, with the identical window inverted
/// (end, start rather than start, end - see the migration's own comment for
/// why that inversion is the exact complement of the quiet window she had).
#[tokio::test]
async fn a_quiet_hours_user_is_migrated_into_a_utc_schedule() {
    let (pool, _guard) = pool_at_0080().await;
    seed(&pool).await;

    apply_0081(&pool).await;

    let ada = vec![0x01u8; 16];
    let header = sqlx::query("SELECT timezone, off_hours_mode, snooze_until FROM notification_schedules WHERE user_id = ?")
        .bind(&ada)
        .fetch_one(&pool)
        .await
        .expect("ada's header row");
    let timezone: String = header.get("timezone");
    let mode: String = header.get("off_hours_mode");
    let snooze: Option<i64> = header.get("snooze_until");
    assert_eq!(timezone, "UTC");
    assert_eq!(mode, "mentions");
    assert_eq!(snooze, None);

    let days = sqlx::query(
        "SELECT weekday, start_minute, end_minute FROM notification_schedule_days
         WHERE user_id = ? ORDER BY weekday",
    )
    .bind(&ada)
    .fetch_all(&pool)
    .await
    .expect("ada's day rows");
    assert_eq!(days.len(), 7, "every weekday gets the same on-hours window");
    for (weekday, row) in days.iter().enumerate() {
        let day: i64 = row.get("weekday");
        let start: i64 = row.get("start_minute");
        let end: i64 = row.get("end_minute");
        assert_eq!(day, weekday as i64);
        assert_eq!((start, end), (100, 900), "the quiet window, inverted");
    }
}

/// A user who never set quiet hours gets no schedule row at all - the same
/// "nothing to carry over" answer `moderation_audit_backfill.rs` asserts for
/// an untouched table.
#[tokio::test]
async fn a_user_with_no_quiet_hours_gets_no_schedule_row() {
    let (pool, _guard) = pool_at_0080().await;
    seed(&pool).await;

    apply_0081(&pool).await;

    let bram = vec![0x02u8; 16];
    let count: i64 =
        sqlx::query_scalar("SELECT count(*) FROM notification_schedules WHERE user_id = ?")
            .bind(&bram)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(count, 0);
}

/// The migration reads `users.quiet_hours_*` but never writes to it: the old
/// old columns keep the exact same values afterward.
#[tokio::test]
async fn the_migration_leaves_the_legacy_columns_untouched() {
    let (pool, _guard) = pool_at_0080().await;
    seed(&pool).await;

    apply_0081(&pool).await;

    let ada = vec![0x01u8; 16];
    let row = sqlx::query(
        "SELECT quiet_hours_start_minute, quiet_hours_end_minute FROM users WHERE id = ?",
    )
    .bind(&ada)
    .fetch_one(&pool)
    .await
    .unwrap();
    let start: i64 = row.get("quiet_hours_start_minute");
    let end: i64 = row.get("quiet_hours_end_minute");
    assert_eq!((start, end), (900, 100));
}
