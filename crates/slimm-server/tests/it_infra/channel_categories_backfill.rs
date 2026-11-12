// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Migration 0031 against real data: the "Text"/"Voice" backfill must leave
//! an existing deployment's rail exactly as it rendered before, per
//! docs/decisions/0006-channel-categories.md.
//!
//! Seeds a database at 0030 (before categories existed) with a text channel,
//! a voice channel, a DM, and a thread, applies 0031 on top, and checks the
//! result through `Store::list_channels` - the same read the rail's own
//! `GET /channels` uses - rather than only over the raw table.

use std::path::Path;
use std::time::Duration;

use slimm_server::ids::ChannelId;
use slimm_server::store::Store;
use sqlx::migrate::Migrator;
use sqlx::sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions};
use sqlx::{Row, SqlitePool};
use uuid::Uuid;

use crate::support;
/// The migration under test. Everything before it is the starting point.
const VERSION: i64 = 31;

const TEXT_CHANNEL: ChannelId = ChannelId(Uuid::from_bytes([0x11; 16]));
const VOICE_CHANNEL: ChannelId = ChannelId(Uuid::from_bytes([0x12; 16]));
const DM_CHANNEL: ChannelId = ChannelId(Uuid::from_bytes([0x13; 16]));
const THREAD_CHANNEL: ChannelId = ChannelId(Uuid::from_bytes([0x14; 16]));

async fn migrator() -> Migrator {
    Migrator::new(Path::new("./migrations"))
        .await
        .expect("resolve migrations")
}

async fn pool_at_0030() -> (SqlitePool, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::empty("slimm-channel-categories-backfill");
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
        "0031 is missing from ./migrations"
    );
    before.migrations = before
        .iter()
        .filter(|m| m.version < VERSION)
        .cloned()
        .collect();
    before.run(&pool).await.expect("migrate to 0030");
    (pool, guard)
}

/// A pre-categories rail: two ordinary channels, a DM, and a thread hanging
/// off a message in the text channel - none of them able to reference a
/// `channel_categories` row that does not exist yet.
async fn seed(pool: &SqlitePool) {
    let statements = [
        "INSERT INTO users (id, username, display_name, password_hash, created_at) VALUES
         (x'01010101010101010101010101010101', 'alice', 'Alice', 'hash', 1)",
        "INSERT INTO channels (id, kind, name, position, created_at) VALUES
         (x'11111111111111111111111111111111', 'text', 'general', 0, 1),
         (x'12121212121212121212121212121212', 'voice', 'lounge', 1, 2),
         (x'13131313131313131313131313131313', 'dm', '', 0, 3)",
        "INSERT INTO channel_seq_counters (channel_id, stream, next_seq) VALUES
         (x'11111111111111111111111111111111', 'message', 2)",
        "INSERT INTO messages (id, channel_id, author_id, seq, content, created_at) VALUES
         (x'21212121212121212121212121212121', x'11111111111111111111111111111111',
          x'01010101010101010101010101010101', 1, 'hello', 100)",
        "INSERT INTO channels (id, kind, name, parent_message_id, created_at) VALUES
         (x'14141414141414141414141414141414', 'text', '',
          x'21212121212121212121212121212121', 101)",
    ];
    for statement in statements {
        sqlx::query(statement)
            .execute(pool)
            .await
            .unwrap_or_else(|e| panic!("seeding failed on {statement}: {e}"));
    }
}

async fn count(pool: &SqlitePool, table: &str) -> i64 {
    sqlx::query_scalar(&format!("SELECT count(*) FROM {table}"))
        .fetch_one(pool)
        .await
        .unwrap_or_else(|e| panic!("counting {table}: {e}"))
}

/// The rail's own read (`Store::list_channels`) must answer with the same
/// channels, in the same order, as it did before the migration ran - the
/// upgrade-must-be-invisible property the decision record names.
#[tokio::test]
async fn the_backfill_leaves_an_existing_rail_unchanged() {
    let (pool, _guard) = pool_at_0030().await;
    seed(&pool).await;

    migrator().await.run(&pool).await.expect("apply 0031");

    let store = Store::new(pool.clone());
    let channels = store.list_channels().await.expect("list channels");
    let ids: Vec<ChannelId> = channels.iter().map(|c| c.id).collect();
    assert_eq!(
        ids,
        vec![TEXT_CHANNEL, VOICE_CHANNEL],
        "the DM and the thread must stay excluded, and the two real channels \
         must keep their pre-migration order"
    );

    assert_eq!(
        count(&pool, "channel_categories WHERE deleted_at IS NULL").await,
        2
    );
    let categories = store.list_categories().await.expect("list categories");
    assert_eq!(categories.len(), 2);
    assert_eq!(categories[0].name, "Text");
    assert_eq!(categories[1].name, "Voice");

    let text = channels
        .iter()
        .find(|c| c.id == TEXT_CHANNEL)
        .expect("text channel");
    assert_eq!(text.category_id, Some(categories[0].id));
    let voice = channels
        .iter()
        .find(|c| c.id == VOICE_CHANNEL)
        .expect("voice channel");
    assert_eq!(voice.category_id, Some(categories[1].id));
}

/// A DM and a thread are excluded from the backfill itself, not merely from
/// the read: neither has ever appeared in `listChannels`, and getting a
/// category assigned would be a fact about a channel this feature was never
/// meant to reach.
#[tokio::test]
async fn the_backfill_never_categorises_a_dm_or_a_thread() {
    let (pool, _guard) = pool_at_0030().await;
    seed(&pool).await;

    migrator().await.run(&pool).await.expect("apply 0031");

    let dm_category: Option<Vec<u8>> = sqlx::query("SELECT category_id FROM channels WHERE id = ?")
        .bind(DM_CHANNEL.0)
        .fetch_one(&pool)
        .await
        .expect("read the dm row")
        .get(0);
    assert!(dm_category.is_none(), "a DM must stay uncategorised");

    let thread_category: Option<Vec<u8>> =
        sqlx::query("SELECT category_id FROM channels WHERE id = ?")
            .bind(THREAD_CHANNEL.0)
            .fetch_one(&pool)
            .await
            .expect("read the thread row")
            .get(0);
    assert!(
        thread_category.is_none(),
        "a thread must stay uncategorised"
    );
}
