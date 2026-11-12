// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Migration 0024 against real data: the rebuild of `messages` onto an
//! explicit rowid alias must lose nothing.
//!
//! The migration's own guard tables refuse a discrepancy from inside the
//! transaction, so a failure there is a rollback rather than damage. This is
//! the other half: it seeds a database at 0023 with a row in every table that
//! references `messages`, applies 0024 on top, and checks the result from
//! outside - column by column, foreign key by foreign key, and through the
//! index rather than only over it.
//!
//! It is also the only place the SQLite the server actually links executes
//! this SQL; everything else about the migration was checked against a CLI.

use std::path::Path;
use std::time::Duration;

use slimm_server::ids::ChannelId;
use slimm_server::store::{MessageSearchFilters, Store};
use sqlx::migrate::Migrator;
use sqlx::sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions};
use sqlx::{Row, SqlitePool};
use uuid::Uuid;

use crate::support;
/// The migration under test. Everything before it is the starting point.
const VERSION: i64 = 24;

/// The seeded channel ids, as the 16-byte blobs `x'11..'` and `x'12..'` spell.
const GENERAL: ChannelId = ChannelId(Uuid::from_bytes([0x11; 16]));

async fn migrator() -> Migrator {
    Migrator::new(Path::new("./migrations"))
        .await
        .expect("resolve migrations")
}

async fn pool_at_0023() -> (SqlitePool, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::empty("slimm-rowid-alias");
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
        "0024 is missing from ./migrations"
    );
    before.migrations = before
        .iter()
        .filter(|m| m.version < VERSION)
        .cloned()
        .collect();
    before.run(&pool).await.expect("migrate to 0023");
    (pool, guard)
}

/// Every table that references `messages`, plus a soft-deleted message and an
/// encrypted one (which no code path can write, so it goes in by hand).
async fn seed(pool: &SqlitePool) {
    let statements = [
        "INSERT INTO users (id, username, display_name, password_hash, created_at) VALUES
         (x'01010101010101010101010101010101', 'alice', 'Alice', 'hash', 1),
         (x'02020202020202020202020202020202', 'bob', 'Bob', 'hash', 2)",
        "INSERT INTO channels (id, kind, name, position, created_at) VALUES
         (x'11111111111111111111111111111111', 'text', 'general', 0, 1),
         (x'12121212121212121212121212121212', 'text', 'random', 1, 2)",
        "INSERT INTO channel_seq_counters (channel_id, stream, next_seq) VALUES
         (x'11111111111111111111111111111111', 'message', 4),
         (x'12121212121212121212121212121212', 'message', 3)",
        "INSERT INTO messages (id, channel_id, author_id, seq, content,
                               is_encrypted, created_at, edited_at, deleted_at) VALUES
         (x'21212121212121212121212121212121', x'11111111111111111111111111111111',
          x'01010101010101010101010101010101', 1, 'hello world alpha', 0, 100, NULL, NULL),
         (x'22222222222222222222222222222222', x'11111111111111111111111111111111',
          x'02020202020202020202020202020202', 2, 'bravo lives here', 0, 101, 105, NULL),
         (x'23232323232323232323232323232323', x'11111111111111111111111111111111',
          NULL, 3, 'charlie was removed', 0, 102, NULL, 200),
         (x'24242424242424242424242424242424', x'12121212121212121212121212121212',
          x'01010101010101010101010101010101', 1, 'delta in random', 0, 103, NULL, NULL),
         (x'25252525252525252525252525252525', x'12121212121212121212121212121212',
          x'02020202020202020202020202020202', 2, 'echo ciphertext', 1, 104, NULL, NULL)",
        "INSERT INTO reactions (message_id, user_id, emoji, created_at) VALUES
         (x'21212121212121212121212121212121', x'02020202020202020202020202020202', ':+1:', 10),
         (x'22222222222222222222222222222222', x'01010101010101010101010101010101', ':eyes:', 11)",
        "INSERT INTO attachments (sha256, size, content_type, key_version, is_encrypted, created_at)
         VALUES (x'ab00000000000000000000000000000000000000000000000000000000000000',
                 3, 'image/png', 0, 0, 1)",
        "INSERT INTO message_attachments (message_id, sha256, position) VALUES
         (x'21212121212121212121212121212121',
          x'ab00000000000000000000000000000000000000000000000000000000000000', 0)",
        "INSERT INTO pinned_messages (channel_id, message_id, pinned_by, pinned_at) VALUES
         (x'11111111111111111111111111111111', x'21212121212121212121212121212121',
          x'01010101010101010101010101010101', 20)",
        "INSERT INTO polls (message_id, channel_id, question, close_at, created_by, created_at)
         VALUES (x'24242424242424242424242424242424', x'12121212121212121212121212121212',
                 'lunch?', NULL, x'01010101010101010101010101010101', 30)",
        "INSERT INTO poll_options (message_id, position, label) VALUES
         (x'24242424242424242424242424242424', 0, 'yes'),
         (x'24242424242424242424242424242424', 1, 'no')",
        "INSERT INTO poll_votes (message_id, user_id, position, voted_at) VALUES
         (x'24242424242424242424242424242424', x'02020202020202020202020202020202', 1, 31)",
    ];
    for statement in statements {
        sqlx::query(statement)
            .execute(pool)
            .await
            .unwrap_or_else(|e| panic!("seeding failed on {statement}: {e}"));
    }
}

/// Every message row, as comparable text, ordered by the rowid the index uses.
async fn message_rows(pool: &SqlitePool) -> Vec<String> {
    sqlx::query(
        "SELECT rowid, hex(id), hex(channel_id), ifnull(hex(author_id), '-'), seq,
                content, is_encrypted, created_at, ifnull(edited_at, -1),
                ifnull(deleted_at, -1)
         FROM messages ORDER BY rowid",
    )
    .fetch_all(pool)
    .await
    .expect("read messages")
    .iter()
    .map(|row| {
        format!(
            "{}|{}|{}|{}|{}|{}|{}|{}|{}|{}",
            row.get::<i64, _>(0),
            row.get::<String, _>(1),
            row.get::<String, _>(2),
            row.get::<String, _>(3),
            row.get::<i64, _>(4),
            row.get::<String, _>(5),
            row.get::<i64, _>(6),
            row.get::<i64, _>(7),
            row.get::<i64, _>(8),
            row.get::<i64, _>(9),
        )
    })
    .collect()
}

/// The ids the index itself answers with, resolved through the join the store
/// uses rather than over the content table.
async fn search_ids(pool: &SqlitePool, query: &str, keyed_on: &str) -> Vec<String> {
    let sql = format!(
        "SELECT substr(hex(m.id), 1, 2) FROM messages_fts
         JOIN messages m ON m.{keyed_on} = messages_fts.rowid
         WHERE messages_fts MATCH ? ORDER BY m.seq"
    );
    sqlx::query(&sql)
        .bind(query)
        .fetch_all(pool)
        .await
        .expect("search")
        .iter()
        .map(|row| row.get::<String, _>(0))
        .collect()
}

async fn count(pool: &SqlitePool, table: &str) -> i64 {
    sqlx::query_scalar(&format!("SELECT count(*) FROM {table}"))
        .fetch_one(pool)
        .await
        .unwrap_or_else(|e| panic!("counting {table}: {e}"))
}

/// Runs the only integrity-check that compares the index with its content
/// table. It refuses any content row the index does not hold, so an encrypted
/// message has to go first - which is exactly why the migration applies this
/// under a `WHERE NOT EXISTS` rather than unconditionally.
async fn checksum_against_content(pool: &SqlitePool) {
    sqlx::query("DELETE FROM messages WHERE is_encrypted <> 0")
        .execute(pool)
        .await
        .expect("drop the rows the index deliberately excludes");
    sqlx::query("INSERT INTO messages_fts(messages_fts, rank) VALUES('integrity-check', 1)")
        .execute(pool)
        .await
        .expect("the index must checksum against its content table");
}

const CHILDREN: [&str; 6] = [
    "reactions",
    "message_attachments",
    "pinned_messages",
    "polls",
    "poll_options",
    "poll_votes",
];

#[tokio::test]
async fn the_rebuild_keeps_every_row_and_every_reference() {
    let (pool, _guard) = pool_at_0023().await;
    seed(&pool).await;

    let rows_before = message_rows(&pool).await;
    let mut children_before = Vec::new();
    for table in CHILDREN {
        children_before.push(count(&pool, table).await);
    }
    let alpha = search_ids(&pool, "alpha", "rowid").await;
    let removed = search_ids(&pool, "removed", "rowid").await;
    assert_eq!(alpha, vec!["21".to_string()]);
    assert_eq!(
        removed,
        vec!["23".to_string()],
        "a soft-deleted message stays in the index; the store filters it later"
    );
    assert!(
        search_ids(&pool, "ciphertext", "rowid").await.is_empty(),
        "an encrypted message is never indexed"
    );

    migrator().await.run(&pool).await.expect("apply 0024");

    assert_eq!(
        message_rows(&pool).await,
        rows_before,
        "every message column, and its rowid, must come back unchanged"
    );
    for (table, before) in CHILDREN.iter().zip(children_before) {
        assert_eq!(count(&pool, table).await, before, "{table} lost rows");
    }

    let violations = sqlx::query("PRAGMA foreign_key_check")
        .fetch_all(&pool)
        .await
        .expect("foreign key check");
    assert!(
        violations.is_empty(),
        "{} dangling references after the rebuild",
        violations.len()
    );

    assert_eq!(search_ids(&pool, "alpha", "fts_rowid").await, alpha);
    assert_eq!(search_ids(&pool, "removed", "fts_rowid").await, removed);
    assert!(
        search_ids(&pool, "ciphertext", "fts_rowid")
            .await
            .is_empty()
    );
    assert_eq!(
        count(&pool, "messages_fts_docsize").await,
        count(&pool, "messages WHERE is_encrypted = 0").await,
        "the index holds one document per plaintext message"
    );

    sqlx::query("INSERT INTO messages_fts(messages_fts) VALUES('integrity-check')")
        .execute(&pool)
        .await
        .expect("the index's own structure must be intact");
    checksum_against_content(&pool).await;

    let leftovers = count(
        &pool,
        "sqlite_master WHERE name LIKE 'messages\\_rebuild%' ESCAPE '\\'",
    )
    .await;
    assert_eq!(leftovers, 0, "holding tables outlived the migration");
}

#[tokio::test]
async fn the_rowid_alias_is_a_real_integer_primary_key() {
    let (pool, _guard) = pool_at_0023().await;
    seed(&pool).await;
    migrator().await.run(&pool).await.expect("apply 0024");

    let column = sqlx::query(
        "SELECT name, type, pk FROM pragma_table_info('messages') WHERE name = 'fts_rowid'",
    )
    .fetch_optional(&pool)
    .await
    .expect("table info")
    .expect("messages has no fts_rowid column");
    assert_eq!(column.get::<String, _>("type"), "INTEGER");
    assert_eq!(
        column.get::<i64, _>("pk"),
        1,
        "fts_rowid must be the primary key, which is what makes it a rowid alias"
    );

    let keyed_on: String = sqlx::query_scalar("SELECT sql FROM sqlite_master WHERE name = ?")
        .bind("messages_fts")
        .fetch_one(&pool)
        .await
        .expect("read the fts declaration");
    assert!(
        keyed_on.contains("content_rowid='fts_rowid'"),
        "the index must name the alias, not the implicit rowid: {keyed_on}"
    );

    assert_eq!(
        count(&pool, "messages WHERE rowid <> fts_rowid").await,
        0,
        "fts_rowid is not aliasing the rowid"
    );
}

/// The triggers keep the index true for writes the store never makes, so they
/// are checked by writing rather than by reading `sqlite_master`.
#[tokio::test]
async fn the_rebuilt_triggers_still_maintain_the_index() {
    let (pool, _guard) = pool_at_0023().await;
    seed(&pool).await;
    migrator().await.run(&pool).await.expect("apply 0024");

    sqlx::query(
        "INSERT INTO messages (id, channel_id, author_id, seq, content, created_at)
         VALUES (x'31313131313131313131313131313131', x'11111111111111111111111111111111',
                 x'01010101010101010101010101010101', 4, 'foxtrot arrived', 100000)",
    )
    .execute(&pool)
    .await
    .expect("insert");
    assert_eq!(
        search_ids(&pool, "foxtrot", "fts_rowid").await,
        vec!["31".to_string()],
        "messages_fts_ai did not index a new message"
    );

    sqlx::query(
        "UPDATE messages SET content = 'golf replaced it'
         WHERE id = x'31313131313131313131313131313131'",
    )
    .execute(&pool)
    .await
    .expect("edit");
    assert!(search_ids(&pool, "foxtrot", "fts_rowid").await.is_empty());
    assert_eq!(
        search_ids(&pool, "golf", "fts_rowid").await,
        vec!["31".to_string()]
    );

    sqlx::query(
        "UPDATE messages SET deleted_at = 1 WHERE id = x'21212121212121212121212121212121'",
    )
    .execute(&pool)
    .await
    .expect("soft delete");
    assert_eq!(
        count(&pool, "pinned_messages").await,
        0,
        "pinned_messages_on_delete was not restored"
    );
    sqlx::query(
        "UPDATE messages SET deleted_at = 1 WHERE id = x'24242424242424242424242424242424'",
    )
    .execute(&pool)
    .await
    .expect("soft delete the poll's message");
    assert_eq!(
        count(&pool, "polls").await,
        0,
        "polls_on_message_delete was not restored"
    );

    sqlx::query("DELETE FROM channels WHERE id = x'11111111111111111111111111111111'")
        .execute(&pool)
        .await
        .expect("cascade the channel away");
    checksum_against_content(&pool).await;
}

/// Pins the reason the migration cannot simply run the strong integrity-check:
/// it treats a content row the index does not hold as corruption, and the
/// `is_encrypted` guard on `messages_fts_ai` produces exactly that row.
#[tokio::test]
async fn the_strong_integrity_check_refuses_an_unindexed_message() {
    let (pool, _guard) = pool_at_0023().await;
    seed(&pool).await;
    migrator().await.run(&pool).await.expect("apply 0024");

    assert_eq!(count(&pool, "messages WHERE is_encrypted <> 0").await, 1);
    let refused =
        sqlx::query("INSERT INTO messages_fts(messages_fts, rank) VALUES('integrity-check', 1)")
            .execute(&pool)
            .await;
    assert!(
        refused.is_err(),
        "if this starts passing, the NOT EXISTS wrapper in 0024 is no longer needed"
    );
    checksum_against_content(&pool).await;
}

/// The store's own search path has to keep working over the rebuilt index,
/// including the filters the raw index does not apply.
#[tokio::test]
async fn the_store_still_searches_over_the_rebuilt_index() {
    let (pool, _guard) = pool_at_0023().await;
    seed(&pool).await;
    migrator().await.run(&pool).await.expect("apply 0024");

    let store = Store::new(pool.clone());
    let hits = store
        .search_messages(
            &[GENERAL],
            Some("alpha"),
            &MessageSearchFilters::default(),
            None,
            20,
        )
        .await
        .expect("search");
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].content, "hello world alpha");

    assert!(
        store
            .search_messages(
                &[GENERAL],
                Some("removed"),
                &MessageSearchFilters::default(),
                None,
                20,
            )
            .await
            .expect("search")
            .is_empty(),
        "a soft-deleted message is indexed but must not be returned"
    );
}
