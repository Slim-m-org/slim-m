// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Embedded SQLite access.
//!
//! Every deployment, official or self-hosted, runs one SQLite database file in
//! WAL mode inside the server process. Persistence lives behind this module so
//! a future Postgres implementation is a swap, not a rewrite.

use std::path::Path;
use std::time::Duration;

use anyhow::Context;
use sqlx::SqlitePool;
use sqlx::sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions, SqliteSynchronous};

use crate::config::Config;

/// How long a request waits for a free connection before it fails, rather than
/// sqlx's 30 s default holding the client for half a minute.
pub(crate) const ACQUIRE_TIMEOUT: Duration = Duration::from_secs(10);

/// Opens the SQLite pool, creating the database and its parent directory if
/// needed, then runs forward-only migrations to the current schema.
pub async fn connect(config: &Config) -> anyhow::Result<SqlitePool> {
    if let Some(parent) = Path::new(&config.database_path).parent()
        && !parent.as_os_str().is_empty()
    {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("creating data directory {}", parent.display()))?;
    }

    let options = SqliteConnectOptions::new()
        .filename(&config.database_path)
        .create_if_missing(true)
        .journal_mode(SqliteJournalMode::Wal)
        .synchronous(SqliteSynchronous::Normal)
        .busy_timeout(Duration::from_secs(5))
        .foreign_keys(true);

    let pool = SqlitePoolOptions::new()
        .max_connections(8)
        .acquire_timeout(ACQUIRE_TIMEOUT)
        .connect_with(options)
        .await
        .context("opening the SQLite database")?;

    sqlx::migrate!("./migrations")
        .run(&pool)
        .await
        .context("running database migrations")?;

    Ok(pool)
}
