// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Migration 0193's triggers, driven straight at the database as a writer that
//! skipped the store would, and its rewrite of the temporary rooms that drifted from their lobby.

use std::path::Path;

use sqlx::migrate::Migrator;
use sqlx::{AssertSqlSafe, SqlitePool};

use crate::support;

fn id(n: u8) -> String {
    format!("x'{}'", format!("{n:02x}").repeat(16))
}

async fn exec(pool: &SqlitePool, sql: &str) -> Result<(), String> {
    sqlx::query(AssertSqlSafe(sql))
        .execute(pool)
        .await
        .map(|_| ())
        .map_err(|e| e.to_string())
}

async fn insert(pool: &SqlitePool, n: u8, parent: Option<u8>) -> Result<(), String> {
    let parent = parent.map_or("NULL".to_owned(), id);
    let sql = format!(
        "INSERT INTO channel_categories (id, name, position, created_at, parent_id)
         VALUES ({}, 'c{n}', {n}, 1, {parent})",
        id(n)
    );
    exec(pool, &sql).await
}

fn refused(result: Result<(), String>, why: &str) {
    match result {
        Ok(()) => panic!("the database accepted it: {why}"),
        Err(e) => assert!(
            e.contains("nests two levels") || e.contains("sub-categories out"),
            "{why}: {e}"
        ),
    }
}

#[tokio::test]
async fn existing_categories_are_top_level_and_unsynced() {
    let (_store, pool, _guard) = support::new_store_with_pool("slimm-nested-migration-seed").await;
    let nested: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM channel_categories WHERE parent_id IS NOT NULL")
            .fetch_one(&pool)
            .await
            .unwrap();
    let synced: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM channel_categories WHERE permissions_synced != 0")
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!((nested, synced), (0, 0));
}

#[tokio::test]
async fn the_triggers_refuse_a_third_level_on_every_write() {
    let (_store, pool, _guard) = support::new_store_with_pool("slimm-nested-migration").await;
    insert(&pool, 1, None).await.unwrap();
    insert(&pool, 2, Some(1)).await.unwrap();
    insert(&pool, 3, None).await.unwrap();

    refused(
        insert(&pool, 4, Some(2)).await,
        "a parent that is a sub-category",
    );
    refused(insert(&pool, 5, Some(5)).await, "its own parent");
    refused(
        insert(&pool, 6, Some(9)).await,
        "a parent that does not exist",
    );
    exec(
        &pool,
        &format!(
            "UPDATE channel_categories SET deleted_at = 1 WHERE id = {}",
            id(3)
        ),
    )
    .await
    .unwrap();
    refused(insert(&pool, 7, Some(3)).await, "a deleted parent");

    insert(&pool, 8, None).await.unwrap();
    let file = |child: u8, parent: u8| {
        format!(
            "UPDATE channel_categories SET parent_id = {} WHERE id = {}",
            id(parent),
            id(child)
        )
    };
    refused(
        exec(&pool, &file(1, 8)).await,
        "moving a category that has sub-categories",
    );
    refused(exec(&pool, &file(8, 2)).await, "under a sub-category");
    refused(exec(&pool, &file(8, 8)).await, "under itself");
    exec(&pool, &file(8, 1)).await.unwrap();
}

#[tokio::test]
async fn a_category_with_live_sub_categories_cannot_be_deleted() {
    let (_store, pool, _guard) = support::new_store_with_pool("slimm-nested-migration-del").await;
    insert(&pool, 1, None).await.unwrap();
    insert(&pool, 2, Some(1)).await.unwrap();
    let delete = format!(
        "UPDATE channel_categories SET deleted_at = 5 WHERE id = {}",
        id(1)
    );
    refused(
        exec(&pool, &delete).await,
        "a parent with a live sub-category",
    );

    let promote = format!(
        "UPDATE channel_categories SET parent_id = NULL WHERE id = {}",
        id(2)
    );
    exec(&pool, &promote).await.unwrap();
    exec(&pool, &delete).await.unwrap();
}

/// A database migrated up to just before 0193, and the full migrator to finish it.
async fn pool_before_0193() -> (SqlitePool, Migrator, support::TestDbGuard) {
    let (pool, guard) = support::migration_db::empty_pool("slimm-nested-migration-rooms").await;
    let full = Migrator::new(Path::new("./migrations")).await.unwrap();
    let mut before = Migrator::new(Path::new("./migrations")).await.unwrap();
    before.migrations = full.iter().filter(|m| m.version < 193).cloned().collect();
    before.run(&pool).await.unwrap();
    (pool, full, guard)
}

async fn rows_of(pool: &SqlitePool, channel: u8) -> Vec<(String, Vec<u8>, i64, i64)> {
    sqlx::query_as(AssertSqlSafe(format!(
        "SELECT target_type, target_id, allow, deny FROM channel_overwrites
         WHERE channel_id = {} ORDER BY target_type, target_id",
        id(channel)
    )))
    .fetch_all(pool)
    .await
    .unwrap()
}

#[tokio::test]
async fn a_live_room_that_drifted_from_its_lobby_is_rewritten_from_it() {
    let (pool, full, _guard) = pool_before_0193().await;
    let seed = format!(
        "INSERT INTO users (id, username, display_name, password_hash, created_at)
           VALUES ({owner}, 'owner', 'Owner', 'h', 1);
         INSERT INTO roles (id, name, permissions, position, is_everyone, created_at) VALUES
           ({gamer}, 'gamer', 0, 1, 0, 1),
           ({guest}, 'guest', 0, 2, 0, 1);
         INSERT INTO channels (id, name, kind, created_at, creates_rooms) VALUES
           ({lobby}, 'lobby', 'voice', 1, 1),
           ({other}, 'other', 'text', 1, 0);
         INSERT INTO channels (id, name, kind, created_at, room_owner_id, room_lobby_id, deleted_at)
           VALUES ({room}, 'room', 'voice', 2, {owner}, {lobby}, NULL),
                  ({gone}, 'gone', 'voice', 2, {owner}, {lobby}, 3),
                  ({bare}, 'bare', 'voice', 2, {owner}, {lobby}, NULL);
         INSERT INTO channel_overwrites (channel_id, target_type, target_id, allow, deny) VALUES
           ({lobby}, 'role', {gamer}, 0, 1024),
           ({lobby}, 'member', {owner}, 1024, 0),
           ({room}, 'role', {gamer}, 1024, 0),
           ({room}, 'role', {guest}, 1024, 0),
           ({gone}, 'role', {guest}, 1024, 0),
           ({other}, 'role', {guest}, 1024, 0)",
        owner = id(1),
        gamer = id(2),
        guest = id(3),
        lobby = id(4),
        room = id(5),
        gone = id(6),
        other = id(7),
        bare = id(8),
    );
    for statement in seed.split(';') {
        sqlx::query(AssertSqlSafe(statement))
            .execute(&pool)
            .await
            .unwrap();
    }
    let gone_before = rows_of(&pool, 6).await;
    let other_before = rows_of(&pool, 7).await;

    full.run(&pool).await.unwrap();

    let lobby = rows_of(&pool, 4).await;
    assert_eq!(lobby.len(), 2, "{lobby:?}");
    assert_eq!(rows_of(&pool, 5).await, lobby, "the drifted room");
    assert_eq!(rows_of(&pool, 8).await, lobby, "a room that held nothing");
    assert_eq!(rows_of(&pool, 6).await, gone_before, "a deleted room");
    assert_eq!(rows_of(&pool, 7).await, other_before, "an ordinary channel");
}
