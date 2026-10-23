// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Migration 0146 against existing data: orphaned category overwrites are
//! removed, valid ones stay, and the pin trigger's delete uses the new index.

use std::path::Path;
use std::time::Duration;

use sqlx::SqlitePool;
use sqlx::migrate::Migrator;
use sqlx::sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions};

mod support;

const VERSION: i64 = 146;

fn id(n: u8) -> String {
    format!("x'{}'", format!("{n:02x}").repeat(16))
}

async fn pool_before() -> (SqlitePool, Migrator, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::empty("slimm-catclean-migration");
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
    assert!(full.iter().any(|m| m.version == VERSION), "0146 is missing");
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
async fn orphaned_category_overwrites_are_removed_and_valid_ones_stay() {
    let (pool, full, _guard) = pool_before().await;
    let seed = format!(
        "INSERT INTO users (id, username, display_name, password_hash, created_at, deleted_at) VALUES
           ({live}, 'live', 'Live', 'h', 1, NULL),
           ({dead}, 'dead', 'Dead', 'h', 1, 5);
         INSERT INTO roles (id, name, permissions, position, is_everyone, created_at)
           VALUES ({role}, 'staff', 0, 1, 0, 1);
         INSERT INTO channel_categories (id, name, position, created_at)
           VALUES ({cat}, 'c', 1, 1);
         INSERT INTO category_overwrites (category_id, target_type, target_id, allow, deny) VALUES
           ({cat}, 'role', {role}, 1, 0),
           ({cat}, 'role', {gone_role}, 1, 0),
           ({cat}, 'member', {live}, 1, 0),
           ({cat}, 'member', {dead}, 1, 0),
           ({cat}, 'member', {gone_user}, 1, 0)",
        live = id(1),
        dead = id(2),
        role = id(3),
        cat = id(4),
        gone_role = id(5),
        gone_user = id(6),
    );
    for statement in seed.split(';') {
        sqlx::query(statement).execute(&pool).await.unwrap();
    }

    full.run(&pool).await.unwrap();

    let kept: Vec<(String, Vec<u8>)> = sqlx::query_as(
        "SELECT target_type, target_id FROM category_overwrites ORDER BY target_type",
    )
    .fetch_all(&pool)
    .await
    .unwrap();
    assert_eq!(kept.len(), 2, "{kept:?}");
    assert_eq!(kept[0], ("member".to_owned(), vec![1u8; 16]));
    assert_eq!(kept[1], ("role".to_owned(), vec![3u8; 16]));
}

#[tokio::test]
async fn the_pin_trigger_delete_searches_by_message_id() {
    let (pool, full, _guard) = pool_before().await;
    full.run(&pool).await.unwrap();
    let plan: Vec<(i64, i64, i64, String)> = sqlx::query_as(
        "EXPLAIN QUERY PLAN DELETE FROM pinned_messages WHERE message_id = x'00000000000000000000000000000000'",
    )
    .fetch_all(&pool)
    .await
    .unwrap();
    let detail = plan
        .iter()
        .map(|r| r.3.as_str())
        .collect::<Vec<_>>()
        .join(" | ");
    println!("{detail}");
    assert!(detail.contains("pinned_messages_message"), "{detail}");
}
