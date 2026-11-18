// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A one-connection pool on an empty database, for the tests that migrate it to a chosen version.

use std::time::Duration;

use sqlx::SqlitePool;
use sqlx::sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions, SqliteSynchronous};

use super::TestDbGuard;

/// The options `db::connect` opens with; `synchronous` matches it so each migration commit does not fsync.
pub fn options(path: &str) -> SqliteConnectOptions {
    SqliteConnectOptions::new()
        .filename(path)
        .create_if_missing(true)
        .journal_mode(SqliteJournalMode::Wal)
        .synchronous(SqliteSynchronous::Normal)
        .busy_timeout(Duration::from_secs(5))
        .foreign_keys(true)
}

/// One connection, so a `PRAGMA` a test sets holds for every later statement.
pub async fn pool(options: SqliteConnectOptions) -> SqlitePool {
    SqlitePoolOptions::new()
        .max_connections(1)
        .connect_with(options)
        .await
        .expect("open migration test pool")
}

/// A fresh database file with no migrations applied, and the guard that removes it.
pub async fn empty_pool(prefix: &str) -> (SqlitePool, TestDbGuard) {
    let (path, guard) = TestDbGuard::empty(prefix);
    (pool(options(&path)).await, guard)
}
