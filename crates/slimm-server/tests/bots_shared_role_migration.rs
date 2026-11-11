// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Migration 0184 against real data: every bot with a token record joins the shared Bots
//! role, managed roles that grant nothing go away, and the rest are left alone.

use std::path::Path;
use std::time::Duration;

use sqlx::SqlitePool;
use sqlx::migrate::Migrator;
use sqlx::sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions};

mod support;

const VERSION: i64 = 184;

async fn migrator() -> Migrator {
    Migrator::new(Path::new("./migrations"))
        .await
        .expect("resolve migrations")
}

async fn pool_at_0183() -> (SqlitePool, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::empty("slimm-bots-shared-role-migration");
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
        "0184 is missing"
    );
    before.migrations = before
        .iter()
        .filter(|m| m.version < VERSION)
        .cloned()
        .collect();
    before.run(&pool).await.expect("migrate to 0183");
    (pool, guard)
}

fn id(n: u8) -> Vec<u8> {
    vec![n; 16]
}

async fn exec(pool: &SqlitePool, sql: &str, binds: &[Vec<u8>]) {
    let mut query = sqlx::query(sql);
    for bind in binds {
        query = query.bind(bind.clone());
    }
    query.execute(pool).await.expect(sql);
}

async fn seed_user(pool: &SqlitePool, n: u8, name: &str, is_bot: bool, token: bool) {
    let flag = i64::from(is_bot);
    sqlx::query(
        "INSERT INTO users (id, username, display_name, created_at, is_bot) VALUES (?, ?, ?, 1, ?)",
    )
    .bind(id(n))
    .bind(name)
    .bind(name)
    .bind(flag)
    .execute(pool)
    .await
    .expect("seed user");
    if !token {
        return;
    }
    exec(
        pool,
        "INSERT INTO devices (id, user_id, name, created_at) VALUES (?, ?, 'd', 1)",
        &[id(n + 100), id(n)],
    )
    .await;
    exec(
        pool,
        "INSERT INTO sessions (id, user_id, device_id, created_at) VALUES (?, ?, ?, 1)",
        &[id(n + 100), id(n), id(n + 100)],
    )
    .await;
    sqlx::query(
        "INSERT INTO bot_tokens (token_hash, bot_user_id, session_id, name, created_at)
         VALUES (?, ?, ?, 'n', 1)",
    )
    .bind(format!("hash{n}"))
    .bind(id(n))
    .bind(id(n + 100))
    .execute(pool)
    .await
    .expect("seed token");
}

async fn seed_managed(pool: &SqlitePool, n: u8, bits: i64) {
    sqlx::query(
        "INSERT INTO roles (id, name, permissions, is_everyone, created_at, managed_bot_id)
         VALUES (?, ?, ?, 0, 1, ?)",
    )
    .bind(id(n + 50))
    .bind(format!("managed{n}"))
    .bind(bits)
    .bind(id(n))
    .execute(pool)
    .await
    .expect("seed role");
    exec(
        pool,
        "INSERT INTO member_roles (user_id, role_id) VALUES (?, ?)",
        &[id(n), id(n + 50)],
    )
    .await;
}

async fn role_names(pool: &SqlitePool, n: u8) -> Vec<String> {
    sqlx::query_scalar(
        "SELECT r.name FROM member_roles mr JOIN roles r ON r.id = mr.role_id
         WHERE mr.user_id = ? ORDER BY r.name",
    )
    .bind(id(n))
    .fetch_all(pool)
    .await
    .unwrap()
}

#[tokio::test]
async fn bots_join_the_shared_role_and_empty_managed_roles_are_removed() {
    let (pool, _guard) = pool_at_0183().await;
    seed_user(&pool, 1, "zero-bot", true, true).await;
    seed_managed(&pool, 1, 0).await;
    seed_user(&pool, 2, "power-bot", true, true).await;
    seed_managed(&pool, 2, 1 << 5).await;
    seed_user(&pool, 3, "bare-bot", true, true).await;
    seed_user(&pool, 4, "module-principal", true, false).await;
    seed_user(&pool, 5, "human", false, false).await;
    migrator().await.run(&pool).await.expect("apply 0184");

    assert_eq!(role_names(&pool, 1).await, ["Bots"]);
    assert_eq!(role_names(&pool, 2).await, ["Bots", "managed2"]);
    assert_eq!(role_names(&pool, 3).await, ["Bots"]);
    assert!(role_names(&pool, 4).await.is_empty(), "module principal");
    assert!(role_names(&pool, 5).await.is_empty(), "human");

    let gone: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM roles WHERE id = ?")
        .bind(id(51))
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(gone, 0, "the empty managed role is deleted");
    let marked: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM roles WHERE is_bots_role = 1 AND name = 'Bots' AND permissions = 0",
    )
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(marked, 1);
}

#[tokio::test]
async fn a_deployment_without_bots_gets_no_bots_role() {
    let (pool, _guard) = pool_at_0183().await;
    seed_user(&pool, 5, "human", false, false).await;
    migrator().await.run(&pool).await.expect("apply 0184");
    let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM roles WHERE is_bots_role = 1")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(count, 0);
}
