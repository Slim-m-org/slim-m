// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A long-lived account is cleared in bounded steps after it is closed, every
//! step is repeatable, and a deletion a stopped server left part way finishes.

use slimm_server::ids::{MessageId, UserId};
use slimm_server::store::{NewMessage, Store};

use crate::support;

fn now_ms() -> i64 {
    let since = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH);
    i64::try_from(since.expect("after 1970").as_millis()).expect("fits")
}

/// More than one batch of each, so the loop has to come round again.
const AUTHORED: usize = 501;

async fn count(pool: &sqlx::SqlitePool, sql: &str, user: UserId) -> i64 {
    sqlx::query_scalar(sqlx::AssertSqlSafe(sql))
        .bind(user)
        .fetch_one(pool)
        .await
        .expect("count")
}

async fn member_with_history(store: &Store, messages: usize) -> UserId {
    let admin = store.create_account("root", "Root", "x").await.unwrap();
    store.bootstrap_deployment(admin.id).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;
    let leaver = store.create_account("ben", "Ben", "x").await.unwrap();
    for _ in 0..messages {
        let id = MessageId::generate();
        store
            .send_message(NewMessage::plain(channel, leaver.id, id, "hi"))
            .await
            .unwrap();
        store.add_reaction(id, leaver.id, "+1").await.unwrap();
    }
    leaver.id
}

#[tokio::test]
async fn a_long_history_is_cleared_across_batches() {
    let (store, pool, _guard) = support::new_store_with_pool("slimm-deletion-batches").await;
    let leaver = member_with_history(&store, AUTHORED).await;

    let deleted = store.delete_account(leaver).await.unwrap();

    let authored = count(
        &pool,
        "SELECT COUNT(*) FROM messages WHERE author_id = ?",
        leaver,
    );
    assert_eq!(authored.await, 0);
    let reacted = count(
        &pool,
        "SELECT COUNT(*) FROM reactions WHERE user_id = ?",
        leaver,
    );
    assert_eq!(reacted.await, 0);
    assert_eq!(deleted.reactions_changed.len(), AUTHORED);
    let pending = count(
        &pool,
        "SELECT COUNT(*) FROM account_purges WHERE user_id = ?",
        leaver,
    );
    assert_eq!(
        pending.await,
        0,
        "a finished deletion leaves nothing pending"
    );
}

/// A server stopped after the account closed but before its content was
/// cleared: the row in `account_purges` is what the sweep finishes from.
#[tokio::test]
async fn an_interrupted_deletion_is_finished_by_the_sweep() {
    let (store, pool, _guard) = support::new_store_with_pool("slimm-deletion-resume").await;
    let leaver = member_with_history(&store, 3).await;
    sqlx::query("UPDATE users SET deleted_at = 1, is_anonymized = 1 WHERE id = ?")
        .bind(leaver)
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query("INSERT INTO account_purges (user_id, started_at) VALUES (?, 1)")
        .bind(leaver)
        .execute(&pool)
        .await
        .unwrap();

    assert_eq!(store.finish_interrupted_account_purges(0).await.unwrap(), 1);

    let authored = count(
        &pool,
        "SELECT COUNT(*) FROM messages WHERE author_id = ?",
        leaver,
    );
    assert_eq!(authored.await, 0);
    let reacted = count(
        &pool,
        "SELECT COUNT(*) FROM reactions WHERE user_id = ?",
        leaver,
    );
    assert_eq!(reacted.await, 0);
    let pending = count(
        &pool,
        "SELECT COUNT(*) FROM account_purges WHERE user_id = ?",
        leaver,
    );
    assert_eq!(pending.await, 0);
}

#[tokio::test]
async fn a_deletion_still_running_is_left_to_itself() {
    let (store, pool, _guard) = support::new_store_with_pool("slimm-deletion-fresh").await;
    let leaver = member_with_history(&store, 1).await;
    sqlx::query("INSERT INTO account_purges (user_id, started_at) VALUES (?, ?)")
        .bind(leaver)
        .bind(now_ms())
        .execute(&pool)
        .await
        .unwrap();

    let finished = store
        .finish_interrupted_account_purges(10 * 60 * 1000)
        .await
        .unwrap();

    assert_eq!(finished, 0);
}
