// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A deleted message keeps nothing readable: its text, earlier versions, embeds
//! and the search terms are gone however the delete happened, and the related
//! lifecycle gaps around it (op reclaim, send replay, forward races, reports).

use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ids::{ChannelId, MessageId, UserId};
use slimm_server::store::{Edited, NewEmbed, NewMessage, SendError, Store};
use sqlx::{AssertSqlSafe, SqlitePool};

use crate::support;
use support::app::register_id as register;

const DAY_MS: i64 = 24 * 60 * 60 * 1000;
const NEEDLE: &str = "hunter2zebra";

async fn harness(name: &str) -> (Store, SqlitePool, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new(name);
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool.clone()), pool, guard)
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
}

async fn general(store: &Store) -> ChannelId {
    store.list_channels().await.unwrap()[0].id
}

async fn send(s: &Store, channel: ChannelId, author: UserId, text: &str) -> MessageId {
    s.send_message(NewMessage::plain(
        channel,
        author,
        MessageId::generate(),
        text,
    ))
    .await
    .unwrap()
    .message
    .id
}

async fn count(pool: &SqlitePool, sql: &'static str, id: MessageId) -> i64 {
    sqlx::query_scalar(sql)
        .bind(id)
        .fetch_one(pool)
        .await
        .unwrap()
}

async fn indexed_terms(pool: &SqlitePool) -> i64 {
    sqlx::query_scalar("SELECT COUNT(*) FROM messages_fts WHERE messages_fts MATCH ?")
        .bind(NEEDLE)
        .fetch_one(pool)
        .await
        .unwrap()
}

async fn stored_content(pool: &SqlitePool, id: MessageId) -> String {
    count_text(pool, "SELECT content FROM messages WHERE id = ?", id).await
}

async fn count_text(pool: &SqlitePool, sql: &'static str, id: MessageId) -> String {
    sqlx::query_scalar(sql)
        .bind(id)
        .fetch_one(pool)
        .await
        .unwrap()
}

async fn assert_scrubbed(pool: &SqlitePool, id: MessageId) {
    assert_eq!(stored_content(pool, id).await, "", "text stays stored");
    assert_eq!(
        count(
            pool,
            "SELECT COUNT(*) FROM message_edits WHERE message_id = ?",
            id
        )
        .await,
        0,
        "earlier versions stay stored"
    );
    assert_eq!(
        count(
            pool,
            "SELECT COUNT(*) FROM message_embeds WHERE message_id = ?",
            id
        )
        .await,
        0,
        "embeds stay stored"
    );
    assert_eq!(indexed_terms(pool).await, 0, "search terms stay indexed");
}

/// A message with an earlier version, an embed and a search-indexed body.
async fn seeded(s: &Store, channel: ChannelId, author: UserId) -> MessageId {
    let id = send(s, channel, author, &format!("first {NEEDLE}")).await;
    let edited = s
        .edit_message(id, &format!("second {NEEDLE}"), author)
        .await
        .unwrap();
    assert!(matches!(edited, Edited::Edited { .. }));
    s.set_message_embeds(
        id,
        &[NewEmbed {
            title: Some(NEEDLE.to_owned()),
            ..NewEmbed::default()
        }],
    )
    .await
    .unwrap();
    id
}

#[tokio::test]
async fn deleting_a_message_scrubs_its_text_versions_embeds_and_search_terms() {
    let (s, pool, _guard) = harness("slimm-scrub-single").await;
    let admin = register(&s, "root").await;
    let channel = general(&s).await;
    let id = seeded(&s, channel, admin).await;
    assert_eq!(indexed_terms(&pool).await, 1);

    assert!(s.delete_message(id, admin).await.unwrap().deleted);

    assert_scrubbed(&pool, id).await;
}

#[tokio::test]
async fn a_bulk_delete_scrubs_every_message_it_removes() {
    let (s, pool, _guard) = harness("slimm-scrub-bulk").await;
    let admin = register(&s, "root").await;
    let channel = general(&s).await;
    let first = seeded(&s, channel, admin).await;
    let second = send(&s, channel, admin, "plain").await;

    s.bulk_delete_messages(channel, &[first, second], admin)
        .await
        .unwrap();

    assert_scrubbed(&pool, first).await;
}

#[tokio::test]
async fn the_retention_prune_scrubs_what_it_deletes() {
    let (s, pool, _guard) = harness("slimm-scrub-retention").await;
    let admin = register(&s, "root").await;
    let channel = general(&s).await;
    let id = seeded(&s, channel, admin).await;
    sqlx::query("UPDATE messages SET created_at = ? WHERE id = ?")
        .bind(-60 * DAY_MS)
        .bind(id)
        .execute(&pool)
        .await
        .unwrap();
    s.set_message_retention_days(30).await.unwrap();

    assert_eq!(s.sweep_message_retention().await.unwrap().pruned.len(), 1);

    assert_scrubbed(&pool, id).await;
}

#[tokio::test]
async fn deleting_a_forwarded_original_scrubs_the_copy_snapshot() {
    let (s, pool, _guard) = harness("slimm-scrub-forward").await;
    let admin = register(&s, "root").await;
    let channel = general(&s).await;
    let other = s.create_channel("other", "text").await.unwrap().id;
    let original = send(&s, channel, admin, &format!("shared {NEEDLE}")).await;
    let source = s.forward_source(original).await.unwrap().unwrap();
    let copy = s
        .send_message(NewMessage {
            forward: Some(source),
            ..NewMessage::plain(other, admin, MessageId::generate(), "")
        })
        .await
        .unwrap()
        .message
        .id;

    s.delete_message(original, admin).await.unwrap();

    let snapshot = count_text(
        &pool,
        "SELECT origin_content FROM message_forwards WHERE message_id = ?",
        copy,
    )
    .await;
    assert_eq!(snapshot, "", "the copy keeps the removed text");
}

#[tokio::test]
async fn the_migration_scrubs_messages_deleted_before_it() {
    let (s, pool, _guard) = harness("slimm-scrub-backfill").await;
    let admin = register(&s, "root").await;
    let channel = general(&s).await;
    let id = seeded(&s, channel, admin).await;
    sqlx::query("DROP TRIGGER messages_scrub_on_delete")
        .execute(&pool)
        .await
        .unwrap();
    s.delete_message(id, admin).await.unwrap();
    assert_eq!(
        indexed_terms(&pool).await,
        1,
        "setup: the text must survive"
    );

    let migration = include_str!("../../migrations/0216_scrub_deleted_messages.sql");
    let backfill = migration
        .split_once("-- The same for everything deleted")
        .expect("backfill section")
        .1
        .split_once('\n')
        .expect("a statement follows")
        .1;
    for statement in backfill.split(';').map(str::trim).filter(|s| !s.is_empty()) {
        let statement = statement
            .lines()
            .filter(|line| !line.trim_start().starts_with("--"))
            .collect::<Vec<_>>()
            .join("\n");
        if statement.trim().is_empty() || statement.contains("CREATE INDEX") {
            continue;
        }
        sqlx::query(AssertSqlSafe(statement))
            .execute(&pool)
            .await
            .unwrap();
    }

    assert_scrubbed(&pool, id).await;
}

#[tokio::test]
async fn a_retried_send_of_a_deleted_message_is_refused_not_replayed() {
    let (s, _pool, _guard) = harness("slimm-scrub-replay").await;
    let admin = register(&s, "root").await;
    let channel = general(&s).await;
    let id = MessageId::generate();
    s.send_message(NewMessage::plain(channel, admin, id, "hello"))
        .await
        .unwrap();
    s.delete_message(id, admin).await.unwrap();

    let retry = s
        .send_message(NewMessage::plain(channel, admin, id, "hello"))
        .await;

    assert!(matches!(retry, Err(SendError::Deleted)), "got {retry:?}");
}

#[tokio::test]
async fn a_forward_whose_source_was_deleted_before_the_send_commits_is_refused() {
    let (s, pool, _guard) = harness("slimm-scrub-forward-race").await;
    let admin = register(&s, "root").await;
    let channel = general(&s).await;
    let other = s.create_channel("other", "text").await.unwrap().id;
    let original = send(&s, channel, admin, &format!("shared {NEEDLE}")).await;
    let source = s.forward_source(original).await.unwrap().unwrap();
    s.delete_message(original, admin).await.unwrap();
    let copy = MessageId::generate();

    let sent = s
        .send_message(NewMessage {
            forward: Some(source),
            ..NewMessage::plain(other, admin, copy, "")
        })
        .await;

    assert!(
        matches!(sent, Err(SendError::ForwardSourceGone)),
        "got {sent:?}"
    );
    let rows: i64 = count(&pool, "SELECT COUNT(*) FROM messages WHERE id = ?", copy).await;
    assert_eq!(rows, 0, "the refused forward left a message behind");
}

#[tokio::test]
async fn replacing_embeds_files_an_edit_op_a_resyncing_client_reads() {
    let (s, _pool, _guard) = harness("slimm-scrub-embed-op").await;
    let admin = register(&s, "root").await;
    let channel = general(&s).await;
    let id = send(&s, channel, admin, "status").await;
    assert!(
        s.message_ops_since(channel, 0, 10)
            .await
            .unwrap()
            .ops
            .is_empty()
    );

    s.replace_message_embeds(id, admin, &[NewEmbed::default()])
        .await
        .unwrap();

    let ops = s.message_ops_since(channel, 0, 10).await.unwrap().ops;
    assert_eq!(ops.len(), 1);
    assert_eq!(ops[0].message_id, id);
}

#[tokio::test]
async fn replacing_embeds_on_a_deleted_message_writes_nothing() {
    let (s, pool, _guard) = harness("slimm-scrub-embed-gone").await;
    let admin = register(&s, "root").await;
    let channel = general(&s).await;
    let id = send(&s, channel, admin, "status").await;
    s.delete_message(id, admin).await.unwrap();

    s.replace_message_embeds(id, admin, &[NewEmbed::default()])
        .await
        .unwrap();

    let embeds = count(
        &pool,
        "SELECT COUNT(*) FROM message_embeds WHERE message_id = ?",
        id,
    )
    .await;
    assert_eq!(embeds, 0);
    assert_eq!(
        s.message_ops_since(channel, 0, 10).await.unwrap().ops.len(),
        1
    );
}

async fn insert_report(pool: &SqlitePool, subject: MessageId, resolved_at: Option<i64>) {
    sqlx::query(
        "INSERT INTO reports (id, subject_kind, subject_id, reason, snapshot, created_at, resolved_at)
         VALUES (randomblob(16), 'message', ?, 'spam', ?, 1, ?)",
    )
    .bind(subject)
    .bind(format!("quoted {NEEDLE}"))
    .bind(resolved_at)
    .execute(pool)
    .await
    .unwrap();
}

async fn snapshots_kept(pool: &SqlitePool) -> i64 {
    sqlx::query_scalar("SELECT COUNT(*) FROM reports WHERE snapshot IS NOT NULL")
        .fetch_one(pool)
        .await
        .unwrap()
}

#[tokio::test]
async fn the_sweep_clears_old_resolved_report_snapshots_only() {
    let (s, pool, _guard) = harness("slimm-scrub-reports").await;
    let admin = register(&s, "root").await;
    let channel = general(&s).await;
    let id = send(&s, channel, admin, "reported").await;
    insert_report(&pool, id, Some(-60 * DAY_MS)).await;
    insert_report(&pool, id, Some(now_ms())).await;
    insert_report(&pool, id, None).await;
    s.set_message_retention_days(30).await.unwrap();

    let swept = s.sweep_message_retention().await.unwrap();

    assert_eq!(swept.reports_cleared, 1);
    assert_eq!(snapshots_kept(&pool).await, 2);
}

#[tokio::test]
async fn deleting_an_account_clears_its_resolved_report_snapshots() {
    let (s, pool, _guard) = harness("slimm-scrub-account-reports").await;
    let _admin = register(&s, "root").await;
    let channel = general(&s).await;
    let member = s.create_user("nia", "Nia").await.unwrap().id;
    let id = send(&s, channel, member, "reported").await;
    insert_report(&pool, id, Some(now_ms())).await;
    insert_report(&pool, id, None).await;

    s.delete_account(member).await.unwrap();

    assert_eq!(
        snapshots_kept(&pool).await,
        1,
        "only the open report keeps its quote"
    );
}

/// Backdated delete ops on `channel`, all naming one message that lives there.
async fn add_ops(pool: &SqlitePool, channel: ChannelId, from: i64, n: i64, created_at: i64) {
    let message: MessageId =
        sqlx::query_scalar("SELECT id FROM messages WHERE channel_id = ? LIMIT 1")
            .bind(channel)
            .fetch_one(pool)
            .await
            .unwrap();
    sqlx::query(
        "WITH RECURSIVE n(i) AS (SELECT ?2 UNION ALL SELECT i + 1 FROM n WHERE i < ?2 + ?3 - 1)
         INSERT INTO message_ops (channel_id, seq, message_id, kind, actor_id, created_at)
         SELECT ?1, i, ?5, 'delete', NULL, ?4 FROM n",
    )
    .bind(channel)
    .bind(from)
    .bind(n)
    .bind(created_at)
    .bind(message)
    .execute(pool)
    .await
    .unwrap();
}

async fn ops_in(pool: &SqlitePool, channel: ChannelId) -> i64 {
    sqlx::query_scalar("SELECT COUNT(*) FROM message_ops WHERE channel_id = ?")
        .bind(channel)
        .fetch_one(pool)
        .await
        .unwrap()
}

#[tokio::test]
async fn op_reclaim_follows_each_channels_own_window() {
    let (s, pool, _guard) = harness("slimm-scrub-reclaim-per-channel").await;
    let _admin = register(&s, "root").await;
    let short = general(&s).await;
    let long = s.create_channel("long", "text").await.unwrap().id;
    s.set_message_retention_days(7).await.unwrap();
    s.set_channel_retention_days(long, Some(365)).await.unwrap();
    send(&s, short, _admin, "x").await;
    send(&s, long, _admin, "x").await;
    add_ops(&pool, short, 1, 3, now_ms() - 20 * DAY_MS).await;
    add_ops(&pool, long, 1, 3, now_ms() - 20 * DAY_MS).await;

    let swept = s.sweep_message_retention().await.unwrap();

    assert_eq!(swept.ops_reclaimed, 3);
    assert_eq!(ops_in(&pool, short).await, 0);
    assert_eq!(
        ops_in(&pool, long).await,
        3,
        "the longer window was ignored"
    );
}

#[tokio::test]
async fn op_reclaim_runs_when_only_a_channel_has_a_window() {
    let (s, pool, _guard) = harness("slimm-scrub-reclaim-space-off").await;
    let _admin = register(&s, "root").await;
    let windowed = general(&s).await;
    let kept = s.create_channel("kept", "text").await.unwrap().id;
    s.set_channel_retention_days(windowed, Some(7))
        .await
        .unwrap();
    send(&s, windowed, _admin, "x").await;
    send(&s, kept, _admin, "x").await;
    add_ops(&pool, windowed, 1, 3, now_ms() - 20 * DAY_MS).await;
    add_ops(&pool, kept, 1, 3, now_ms() - 20 * DAY_MS).await;

    s.sweep_message_retention().await.unwrap();

    assert_eq!(ops_in(&pool, windowed).await, 0);
    assert_eq!(
        ops_in(&pool, kept).await,
        3,
        "no window, so nothing is reclaimed"
    );
}

#[tokio::test]
async fn one_sweep_reclaims_a_backlog_larger_than_a_batch() {
    let (s, pool, _guard) = harness("slimm-scrub-reclaim-backlog").await;
    let _admin = register(&s, "root").await;
    let channel = general(&s).await;
    s.set_message_retention_days(7).await.unwrap();
    send(&s, channel, _admin, "x").await;
    add_ops(&pool, channel, 1, 5_000, now_ms() - 20 * DAY_MS).await;

    let swept = s.sweep_message_retention().await.unwrap();

    assert_eq!(swept.ops_reclaimed, 5_000);
    assert_eq!(ops_in(&pool, channel).await, 0);
}
