// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Counts and read-backs that disagreed with what members can see: the saved
//! and thread ceilings counting deleted messages, per-channel bytes counting a
//! re-posted file per message, and an edit racing a delete (issues 2052-2056).

use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ids::{ChannelId, MessageId, UserId};
use slimm_server::store::{MAX_SAVED_MESSAGES, MAX_THREADS_PER_CHANNEL, NewMessage, Store};
use sqlx::SqlitePool;

mod support;

async fn store(name: &str) -> (Store, SqlitePool, UserId, ChannelId, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new(name);
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    let s = Store::new(pool.clone());
    let user = s.create_account("ann", "Ann", "x").await.unwrap();
    s.bootstrap_deployment(user.id).await.unwrap();
    let channel = s.create_channel("general-audit", "text").await.unwrap();
    (s, pool, user.id, channel.id, guard)
}

async fn send(s: &Store, channel: ChannelId, user: UserId, text: &str) -> MessageId {
    let id = MessageId::generate();
    s.send_message(NewMessage::plain(channel, user, id, text))
        .await
        .unwrap();
    id
}

async fn soft_delete(pool: &SqlitePool, id: MessageId) {
    let done = sqlx::query("UPDATE messages SET deleted_at = 1 WHERE id = ?")
        .bind(id)
        .execute(pool)
        .await
        .unwrap();
    assert_eq!(done.rows_affected(), 1);
}

#[tokio::test]
async fn saves_of_deleted_messages_do_not_hold_a_slot() {
    let (s, pool, user, channel, _guard) = store("slimm-audit-saved").await;
    let mut first = None;
    for i in 0..MAX_SAVED_MESSAGES {
        let id = send(&s, channel, user, &format!("m{i}")).await;
        s.save_message(user, id).await.unwrap();
        first.get_or_insert(id);
    }
    soft_delete(&pool, first.unwrap()).await;

    let fresh = send(&s, channel, user, "one more").await;
    assert!(
        s.save_message(user, fresh).await.is_ok(),
        "a save nobody can see or remove still counted toward the ceiling"
    );
}

#[tokio::test]
async fn threads_under_deleted_parents_do_not_hold_a_slot() {
    let (s, pool, user, channel, _guard) = store("slimm-audit-threads").await;
    let mut first = None;
    for i in 0..MAX_THREADS_PER_CHANNEL {
        let id = send(&s, channel, user, &format!("p{i}")).await;
        s.open_thread(channel, id).await.unwrap();
        first.get_or_insert(id);
    }
    soft_delete(&pool, first.unwrap()).await;

    let parent = send(&s, channel, user, "one more").await;
    assert!(
        s.open_thread(channel, parent).await.is_ok(),
        "a thread the list hides still counted toward the ceiling"
    );
}

#[tokio::test]
async fn a_file_posted_three_times_counts_once_per_channel() {
    let (s, _pool, user, channel, _guard) = store("slimm-audit-bytes").await;
    s.store_attachment(&[7; 32], 4_000, "image/png", "a.png", Some(user))
        .await
        .unwrap();
    for i in 0..3 {
        let text = format!("again {i}");
        s.send_message(NewMessage {
            attachment_ids: &[[7; 32].to_vec()],
            spoiler_ids: &[],
            ..NewMessage::plain(channel, user, MessageId::generate(), &text)
        })
        .await
        .unwrap();
    }

    let rows = s.attachment_bytes_by_channel(10).await.unwrap();
    let total = s.attachment_bytes_total().await.unwrap();
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].attachment_bytes, 4_000);
    assert!(rows[0].attachment_bytes <= total);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_edit_racing_a_delete_never_errors() {
    let (s, _pool, user, channel, _guard) = store("slimm-audit-edit-race").await;
    for i in 0..200 {
        let id = send(&s, channel, user, "before").await;
        let editor = s.clone();
        let edit =
            tokio::spawn(async move { editor.edit_message(id, &format!("after {i}"), user).await });
        let deleter = s.clone();
        let delete = tokio::spawn(async move { deleter.delete_message(id, user).await });
        delete.await.unwrap().unwrap();
        let edit = edit.await.unwrap();
        assert!(edit.is_ok(), "edit {i} failed: {:?}", edit.err());
    }
}
