// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Every rebuild of `moderation_audit_log` against real data: each copies the
//! table, and a copy is where audit rows get lost. 0049 has its own test in
//! `moderation_audit_action_widening.rs`; this covers the rest (issue 2062)
//! and 0118, the rebuild that ends them (issue 1832).

use std::path::Path;
use std::time::Duration;

use sqlx::migrate::Migrator;
use sqlx::sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions};
use sqlx::{Row, SqlitePool};

mod support;

const REBUILDS: [i64; 6] = [77, 86, 92, 94, 98, 118];

type AuditRow = (
    i64,
    Option<Vec<u8>>,
    Vec<u8>,
    String,
    Option<String>,
    Option<i64>,
    i64,
);

async fn migrator_through(last: i64) -> Migrator {
    let mut migrator = Migrator::new(Path::new("./migrations"))
        .await
        .expect("resolve migrations");
    assert!(
        migrator.iter().any(|m| m.version == last),
        "{last} is missing"
    );
    migrator.migrations = migrator
        .iter()
        .filter(|m| m.version <= last)
        .cloned()
        .collect();
    migrator
}

async fn pool_before(version: i64) -> (SqlitePool, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::empty(&format!("slimm-audit-rebuild-{version}"));
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
    migrator_through(version - 1)
        .await
        .run(&pool)
        .await
        .expect("migrate to the version before");
    (pool, guard)
}

/// The actions the table's own CHECK allows right now.
async fn allowed_actions(pool: &SqlitePool) -> Vec<String> {
    let sql: String = sqlx::query_scalar(
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'moderation_audit_log'",
    )
    .fetch_one(pool)
    .await
    .unwrap();
    let list = sql
        .split("action IN (")
        .nth(1)
        .and_then(|rest| rest.split(')').next())
        .expect("the CHECK lists its actions");
    list.split(',')
        .map(|word| word.trim().trim_matches('\'').to_owned())
        .collect()
}

async fn seed(pool: &SqlitePool, actions: &[String]) {
    sqlx::query(
        "INSERT INTO users (id, username, display_name, password_hash, created_at) VALUES
         (x'01010101010101010101010101010101', 'ada', 'Ada', 'hash', 1),
         (x'02020202020202020202020202020202', 'nia', 'Nia', 'hash', 1)",
    )
    .execute(pool)
    .await
    .unwrap();
    for (i, action) in actions.iter().enumerate() {
        let until = matches!(action.as_str(), "timeout" | "timeout_cleared").then_some(9_999);
        let actor = (i % 3 != 0).then_some(vec![1u8; 16]);
        sqlx::query(
            "INSERT INTO moderation_audit_log (actor_id, subject_id, action, reason, until, created_at)
             VALUES (?, x'02020202020202020202020202020202', ?, ?, ?, ?)",
        )
        .bind(actor)
        .bind(action)
        .bind(format!("reason {i}"))
        .bind(until)
        .bind(1_000 + i as i64)
        .execute(pool)
        .await
        .unwrap_or_else(|e| panic!("seeding {action} failed: {e}"));
    }
}

async fn rows(pool: &SqlitePool) -> Vec<AuditRow> {
    sqlx::query("SELECT * FROM moderation_audit_log ORDER BY id")
        .fetch_all(pool)
        .await
        .unwrap()
        .iter()
        .map(|r| {
            (
                r.get("id"),
                r.get("actor_id"),
                r.get("subject_id"),
                r.get("action"),
                r.get("reason"),
                r.get("until"),
                r.get("created_at"),
            )
        })
        .collect()
}

async fn indexes(pool: &SqlitePool) -> Vec<String> {
    sqlx::query_scalar(
        "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'moderation_audit_log'
         AND name NOT LIKE 'sqlite_%' ORDER BY name",
    )
    .fetch_all(pool)
    .await
    .unwrap()
}

#[tokio::test]
async fn every_rebuild_keeps_every_row_and_index() {
    for version in REBUILDS {
        let (pool, _guard) = pool_before(version).await;
        let actions = allowed_actions(&pool).await;
        seed(&pool, &actions).await;
        let (before, before_indexes) = (rows(&pool).await, indexes(&pool).await);
        assert_eq!(before.len(), actions.len());

        migrator_through(version)
            .await
            .run(&pool)
            .await
            .expect("apply the rebuild");

        assert_eq!(
            rows(&pool).await,
            before,
            "{version} changed or lost audit rows"
        );
        let after_indexes = indexes(&pool).await;
        for index in &before_indexes {
            assert!(
                after_indexes.contains(index),
                "{version} dropped index {index}"
            );
        }
    }
}

#[tokio::test]
async fn after_0118_a_new_action_needs_no_migration_but_junk_is_refused() {
    let (pool, _guard) = pool_before(119).await;
    let actions = allowed_actions_or_none(&pool).await;
    assert!(
        actions.is_none(),
        "0118 should leave no action list in the CHECK"
    );
    seed(&pool, &["remove".to_owned()]).await;
    let insert = |action: &'static str| {
        sqlx::query(
            "INSERT INTO moderation_audit_log (subject_id, action, created_at)
             VALUES (x'02020202020202020202020202020202', ?, 1)",
        )
        .bind(action)
        .execute(&pool)
    };
    assert!(insert("future_act").await.is_ok());
    assert!(insert("act2").await.is_ok());
    assert!(insert("a1_b").await.is_ok());
    assert!(
        insert(Box::leak("a".repeat(64).into_boxed_str()))
            .await
            .is_ok()
    );
    assert!(
        insert(Box::leak("a".repeat(65).into_boxed_str()))
            .await
            .is_err()
    );
    assert!(insert("Bad Act!").await.is_err());
    assert!(insert("UPPER").await.is_err());
    assert!(insert("").await.is_err());
}

async fn allowed_actions_or_none(pool: &SqlitePool) -> Option<String> {
    let sql: String = sqlx::query_scalar(
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'moderation_audit_log'",
    )
    .fetch_one(pool)
    .await
    .unwrap();
    sql.contains("action IN (").then_some(sql)
}
