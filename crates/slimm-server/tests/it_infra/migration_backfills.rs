// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The data backfills inside migrations 0125 (a bot's assigned prefix), 0144
//! (a canvas clear's affected count) and 0194 (voice data per message), run
//! against rows that existed before them.

use std::path::Path;
use std::time::Duration;

use sqlx::SqlitePool;
use sqlx::migrate::Migrator;
use sqlx::sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions};

use crate::support;
fn id(n: u8) -> String {
    format!("x'{}'", format!("{n:02x}").repeat(16))
}

/// A database migrated up to, not including, `version`, and the full migrator to finish it with.
async fn pool_before(version: i64) -> (SqlitePool, Migrator, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::empty("slimm-backfill-migration");
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
    assert!(
        full.iter().any(|m| m.version == version),
        "{version} is missing"
    );
    let mut before = Migrator::new(Path::new("./migrations")).await.unwrap();
    before.migrations = full
        .iter()
        .filter(|m| m.version < version)
        .cloned()
        .collect();
    before.run(&pool).await.unwrap();
    (pool, full, guard)
}

async fn seed(pool: &SqlitePool, statements: &str) {
    for statement in statements.split(';') {
        sqlx::query(statement).execute(pool).await.unwrap();
    }
}

#[tokio::test]
async fn a_bot_with_a_registration_adopts_its_prefix_and_the_rest_stay_unassigned() {
    let (pool, full, _guard) = pool_before(125).await;
    seed(
        &pool,
        &format!(
            "INSERT INTO users (id, username, display_name, password_hash, created_at, is_bot) VALUES
               ({registered}, 'registered', 'Registered', 'h', 1, 1),
               ({silent}, 'silent', 'Silent', 'h', 1, 1),
               ({human}, 'human', 'Human', 'h', 1, 0);
             INSERT INTO bot_command_registrations (bot_user_id, prefix, updated_at)
               VALUES ({registered}, '!', 1)",
            registered = id(1),
            silent = id(2),
            human = id(3),
        ),
    )
    .await;

    full.run(&pool).await.unwrap();

    let prefixes: Vec<(Vec<u8>, Option<String>)> =
        sqlx::query_as("SELECT id, bot_prefix FROM users ORDER BY id")
            .fetch_all(&pool)
            .await
            .unwrap();
    assert_eq!(
        prefixes,
        vec![
            (vec![1u8; 16], Some("!".to_owned())),
            (vec![2u8; 16], None),
            (vec![3u8; 16], None),
        ]
    );
}

#[tokio::test]
async fn a_clear_keeps_the_count_it_originally_removed() {
    let (pool, full, _guard) = pool_before(144).await;
    let (channel, other) = (id(10), id(11));
    // Five objects; a clear at t=100 bound to seq 3 removed seqs 1 and 2 (seq 3 was already gone at t=50).
    seed(
        &pool,
        &format!(
            "INSERT INTO channels (id, name, kind, position, created_at) VALUES
               ({channel}, 'canvas', 'canvas', 0, 0),
               ({other}, 'other', 'canvas', 1, 0);
             INSERT INTO canvas_objects (id, channel_id, channel_key, kind, seq, created_at, deleted_at) VALUES
               (randomblob(16), {channel}, 1, 'stroke', 1, 1, 100),
               (randomblob(16), {channel}, 1, 'stroke', 2, 2, 100),
               (randomblob(16), {channel}, 1, 'stroke', 3, 3, 50),
               (randomblob(16), {channel}, 1, 'stroke', 4, 4, NULL),
               (randomblob(16), {channel}, 1, 'stroke', 5, 5, 100),
               (randomblob(16), {other}, 2, 'stroke', 1, 1, 100);
             INSERT INTO canvas_ops (channel_id, seq, id, kind, bound_seq, created_at) VALUES
               ({channel}, 1, randomblob(16), 'place', NULL, 1),
               ({channel}, 2, randomblob(16), 'clear', 3, 100),
               ({other}, 1, randomblob(16), 'clear', 1, 100),
               ({other}, 2, randomblob(16), 'clear', 0, 200)",
        ),
    )
    .await;

    full.run(&pool).await.unwrap();

    let rows: Vec<(Vec<u8>, i64, Option<i64>)> =
        sqlx::query_as("SELECT channel_id, seq, affected FROM canvas_ops ORDER BY channel_id, seq")
            .fetch_all(&pool)
            .await
            .unwrap();
    assert_eq!(
        rows,
        vec![
            (vec![10u8; 16], 1, None),
            (vec![10u8; 16], 2, Some(2)),
            (vec![11u8; 16], 1, Some(1)),
            (vec![11u8; 16], 2, Some(0)),
        ]
    );
}

#[tokio::test]
async fn undoing_a_clear_does_not_change_its_stored_count() {
    let (pool, full, _guard) = pool_before(144).await;
    let channel = id(10);
    seed(
        &pool,
        &format!(
            "INSERT INTO channels (id, name, kind, position, created_at) VALUES ({channel}, 'canvas', 'canvas', 0, 0);
             INSERT INTO canvas_objects (id, channel_id, channel_key, kind, seq, created_at, deleted_at) VALUES
               (randomblob(16), {channel}, 1, 'stroke', 1, 1, 100),
               (randomblob(16), {channel}, 1, 'stroke', 2, 2, 100);
             INSERT INTO canvas_ops (channel_id, seq, id, kind, bound_seq, created_at) VALUES
               ({channel}, 1, randomblob(16), 'clear', 2, 100)",
        ),
    )
    .await;
    full.run(&pool).await.unwrap();

    sqlx::query("UPDATE canvas_objects SET deleted_at = NULL")
        .execute(&pool)
        .await
        .unwrap();

    let affected: Option<i64> = sqlx::query_scalar("SELECT affected FROM canvas_ops WHERE seq = 1")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(
        affected,
        Some(2),
        "the count must outlive the fence it was derived from"
    );
}

fn sha(n: u8) -> String {
    format!("x'{}'", format!("{n:02x}").repeat(32))
}

/// A row of voice data as stored: sha256, owner id, length and waveform.
type StoredVoice = (Vec<u8>, Vec<u8>, Option<i64>, Option<Vec<u8>>);

/// Voice data 0194 moved off the blob, as (sha256 first byte, user or message first byte, ms, first bucket).
async fn voice_rows(
    pool: &SqlitePool,
    table: &str,
    owner: &str,
) -> Vec<(u8, u8, Option<i64>, Option<u8>)> {
    let sql = format!(
        "SELECT substr(sha256, 1, 1), substr({owner}, 1, 1), voice_duration_ms, substr(voice_waveform, 1, 1)
         FROM {table} ORDER BY sha256, {owner}"
    );
    let rows: Vec<StoredVoice> = sqlx::query_as(&sql).fetch_all(pool).await.unwrap();
    rows.into_iter()
        .map(|(sha, owner, ms, wave)| (sha[0], owner[0], ms, wave.map(|w| w[0])))
        .collect()
}

#[tokio::test]
async fn every_voice_message_stays_one_and_only_a_sole_uploader_keeps_an_unsent_mark() {
    let (pool, full, _guard) = pool_before(194).await;
    let (alice, bob, channel) = (id(1), id(2), id(10));
    let (recorded, reshared, plain) = (sha(0xa1), sha(0xa2), sha(0xa3));
    let loud = "00".repeat(63);
    seed(
        &pool,
        &format!(
            "INSERT INTO users (id, username, display_name, password_hash, created_at) VALUES
               ({alice}, 'alice', 'Alice', 'h', 1), ({bob}, 'bob', 'Bob', 'h', 1);
             INSERT INTO channels (id, name, kind, position, created_at) VALUES
               ({channel}, 'general', 'text', 0, 0);
             INSERT INTO attachments (sha256, size, content_type, key_version, is_encrypted, created_at) VALUES
               ({recorded}, 9, 'audio/ogg', 0, 0, 1), ({reshared}, 9, 'audio/ogg', 0, 0, 1),
               ({plain}, 9, 'audio/mpeg', 0, 0, 1);
             INSERT INTO attachment_voice (sha256, duration_ms, waveform) VALUES
               ({recorded}, 4200, zeroblob(64)), ({reshared}, 900, x'07{loud}');
             INSERT INTO attachment_uploaders (sha256, uploaded_by, uploaded_at) VALUES
               ({recorded}, {alice}, 1), ({reshared}, {alice}, 1), ({reshared}, {bob}, 2),
               ({plain}, {alice}, 1);
             INSERT INTO messages (id, channel_id, author_id, seq, content, created_at) VALUES
               ({m1}, {channel}, {alice}, 1, '', 1), ({m2}, {channel}, {bob}, 2, '', 2),
               ({m3}, {channel}, {bob}, 3, '', 3);
             INSERT INTO message_attachments (message_id, sha256, position) VALUES
               ({m1}, {recorded}, 0), ({m2}, {recorded}, 0), ({m2}, {reshared}, 1),
               ({m3}, {plain}, 0)",
            m1 = id(0x21),
            m2 = id(0x22),
            m3 = id(0x23),
        ),
    )
    .await;

    full.run(&pool).await.unwrap();

    assert_eq!(
        voice_rows(&pool, "message_attachments", "message_id").await,
        vec![
            (0xa1, 0x21, Some(4200), Some(0)),
            (0xa1, 0x22, Some(4200), Some(0)),
            (0xa2, 0x22, Some(900), Some(7)),
            (0xa3, 0x23, None, None),
        ],
        "every link of a voice blob still shows as a voice message"
    );
    assert_eq!(
        voice_rows(&pool, "attachment_uploaders", "uploaded_by").await,
        vec![
            (0xa1, 0x01, Some(4200), Some(0)),
            (0xa2, 0x01, None, None),
            (0xa2, 0x02, None, None),
            (0xa3, 0x01, None, None),
        ]
    );
    let left: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'attachment_voice'",
    )
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(left, 0, "nothing reads a per-blob mark any more");
}
