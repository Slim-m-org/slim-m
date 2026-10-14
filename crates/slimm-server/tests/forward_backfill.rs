// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The one-off pass for forwarded copies whose original was deleted before copies followed it.

mod support;

use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ids::{ChannelId, MessageId, UserId};
use slimm_server::store::{NewMessage, Store};
use sqlx::{Row, SqlitePool};

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

async fn forward(
    store: &Store,
    channel: ChannelId,
    by: UserId,
    of: MessageId,
    note: &str,
) -> MessageId {
    let source = store.forward_source(of).await.unwrap().unwrap();
    let id = MessageId::generate();
    store
        .send_message(NewMessage {
            channel_id: channel,
            author_id: by,
            id,
            content: note,
            attachment_ids: &[],
            spoiler_ids: &[],
            reply_to_id: None,
            forward: Some(source.origin),
        })
        .await
        .unwrap();
    id
}

async fn send(store: &Store, channel: ChannelId, by: UserId, text: &str) -> MessageId {
    let id = MessageId::generate();
    store
        .send_message(NewMessage::plain(channel, by, id, text))
        .await
        .unwrap();
    id
}

/// Deletes without the cascade, the way an original went before copies followed it.
async fn delete_the_old_way(pool: &SqlitePool, id: MessageId) {
    sqlx::query("UPDATE messages SET deleted_at = 1 WHERE id = ?")
        .bind(id)
        .execute(pool)
        .await
        .unwrap();
}

async fn deleted(pool: &SqlitePool, id: MessageId) -> bool {
    let at: Option<i64> = sqlx::query("SELECT deleted_at FROM messages WHERE id = ?")
        .bind(id)
        .fetch_one(pool)
        .await
        .unwrap()
        .get(0);
    at.is_some()
}

async fn snapshot(pool: &SqlitePool, id: MessageId) -> (Option<i64>, String) {
    let row = sqlx::query(
        "SELECT origin_removed_at, origin_content FROM message_forwards WHERE message_id = ?",
    )
    .bind(id)
    .fetch_one(pool)
    .await
    .unwrap();
    (row.get(0), row.get(1))
}

#[tokio::test]
async fn orphaned_copies_follow_their_deleted_original_and_nothing_else_moves() {
    let (store, pool, _guard) = harness("slimm-forward-backfill").await;
    let admin = store
        .create_account("root", "Root", "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(admin.id).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;

    let gone = send(&store, channel, admin.id, "deleted long ago").await;
    let bare = forward(&store, channel, admin.id, gone, "").await;
    let noted = forward(&store, channel, admin.id, gone, "look at this").await;
    delete_the_old_way(&pool, gone).await;

    let alive = send(&store, channel, admin.id, "still here").await;
    let alive_copy = forward(&store, channel, admin.id, alive, "").await;

    let first = store.backfill_orphaned_forwards().await.unwrap();
    assert_eq!(first.deleted.len(), 1);
    assert_eq!(first.detached.len(), 1);
    assert!(deleted(&pool, bare).await, "a bare copy is soft deleted");
    assert!(!deleted(&pool, noted).await, "a copy with a note is kept");
    let (removed_at, content) = snapshot(&pool, noted).await;
    assert!(
        removed_at.is_some() && content.is_empty(),
        "but loses its snapshot"
    );
    assert!(
        !deleted(&pool, alive_copy).await,
        "a copy of a live original is untouched"
    );
    assert_eq!(
        snapshot(&pool, alive_copy).await,
        (None, "still here".to_owned())
    );

    let second = store.backfill_orphaned_forwards().await.unwrap();
    assert!(
        second.deleted.is_empty() && second.detached.is_empty(),
        "a rerun finds nothing"
    );
}
