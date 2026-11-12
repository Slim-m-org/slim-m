// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Migration 0097 against existing data: an account whose device opted in
//! keeps previews on, everyone else is left unset, and no row is lost.

use std::path::Path;
use std::time::Duration;

use sqlx::SqlitePool;
use sqlx::migrate::Migrator;
use sqlx::sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions};

use crate::support;
const VERSION: i64 = 97;

fn id(n: u8) -> String {
    format!("x'{}'", format!("{n:02x}").repeat(16))
}

async fn pool_before() -> (SqlitePool, Migrator, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::empty("slimm-push-preview-migration");
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
    assert!(full.iter().any(|m| m.version == VERSION), "0097 is missing");
    let mut before = Migrator::new(Path::new("./migrations")).await.unwrap();
    before.migrations = full
        .iter()
        .filter(|m| m.version < VERSION)
        .cloned()
        .collect();
    before.run(&pool).await.unwrap();
    (pool, full, guard)
}

#[tokio::test]
async fn opted_in_accounts_are_seeded_and_the_rest_stay_unset() {
    let (pool, full, _guard) = pool_before().await;
    let users = format!(
        "INSERT INTO users (id, username, display_name, password_hash, created_at) VALUES
         ({a}, 'on', 'On', 'h', 1), ({b}, 'mixed', 'Mixed', 'h', 2), ({c}, 'off', 'Off', 'h', 3),
         ({d}, 'none', 'None', 'h', 4)",
        a = id(1),
        b = id(2),
        c = id(3),
        d = id(4)
    );
    let devices = format!(
        "INSERT INTO devices (id, user_id, name, created_at, push_include_content) VALUES
         ({d1}, {a}, 'p', 1, 1), ({d2}, {b}, 'old', 1, 1), ({d3}, {b}, 'new', 2, 0),
         ({d4}, {c}, 'p', 1, 0)",
        d1 = id(11),
        d2 = id(12),
        d3 = id(13),
        d4 = id(14),
        a = id(1),
        b = id(2),
        c = id(3)
    );
    sqlx::query(&users).execute(&pool).await.unwrap();
    sqlx::query(&devices).execute(&pool).await.unwrap();
    let devices_before: Vec<(Vec<u8>, i64)> =
        sqlx::query_as("SELECT id, push_include_content FROM devices ORDER BY id")
            .fetch_all(&pool)
            .await
            .unwrap();

    full.run(&pool).await.unwrap();

    let seeded: Vec<(String, Option<i64>)> =
        sqlx::query_as("SELECT username, push_include_content FROM users ORDER BY username")
            .fetch_all(&pool)
            .await
            .unwrap();
    assert_eq!(
        seeded,
        vec![
            ("mixed".to_owned(), Some(1)),
            ("none".to_owned(), None),
            ("off".to_owned(), None),
            ("on".to_owned(), Some(1)),
        ]
    );
    let devices_after: Vec<(Vec<u8>, i64)> =
        sqlx::query_as("SELECT id, push_include_content FROM devices ORDER BY id")
            .fetch_all(&pool)
            .await
            .unwrap();
    assert_eq!(devices_before, devices_after);
}
