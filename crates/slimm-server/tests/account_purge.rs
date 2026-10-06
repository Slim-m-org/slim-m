// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What deleting an account removes outright, as opposed to what it
//! anonymizes and leaves standing (`account_anonymization.rs`).
//!
//! The split is the codebase's own rule: content other people can still see
//! keeps its row and loses its author id, and everything that is only the
//! person's own is deleted. Each of these was found by
//! `account_deletion_coverage.rs`'s audit rather than by anybody hitting it,
//! and each carried an `ON DELETE CASCADE` that reads like it already
//! handled the case. It does not: deleting an account here is a tombstone
//! `UPDATE` setting `deleted_at`, so no cascade ever fires.

mod support;

use slimm_server::ids::MessageId;
use slimm_server::notifications::NotificationPreference;
use slimm_server::store::{NewMessage, Store};
use sqlx::Row;

async fn new_store() -> (Store, sqlx::SqlitePool, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new("slimm-purge");
    let config = slimm_server::config::Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..slimm_server::config::Config::default()
    };
    let pool = slimm_server::db::connect(&config)
        .await
        .expect("connect + migrate");
    (Store::new(pool.clone()), pool, guard)
}

async fn count(pool: &sqlx::SqlitePool, sql: &str, user: slimm_server::ids::UserId) -> i64 {
    sqlx::query(sql)
        .bind(user)
        .fetch_one(pool)
        .await
        .expect("count")
        .get::<i64, _>(0)
}

/// How somebody voted is theirs, exactly as which emoji they reacted with is,
/// and reactions have always been purged. The tally moves as a result, which
/// is the same thing that happens to a reaction count.
#[tokio::test]
async fn deleting_an_account_takes_its_poll_votes() {
    let (store, pool, _guard) = new_store().await;
    let admin = store
        .create_account("root", "Root", "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(admin.id).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;

    let voter = store
        .create_account("voter", "Voter", "not-a-real-hash")
        .await
        .unwrap();
    let poll_message = MessageId::generate();
    store
        .send_poll_message(
            channel,
            admin.id,
            poll_message,
            "vote",
            slimm_server::store::NewPoll {
                question: "lunch?",
                options: &["yes".into(), "no".into()],
                close_at: None,
            },
        )
        .await
        .unwrap();
    store.vote_poll(poll_message, voter.id, 0).await.unwrap();
    assert_eq!(
        count(
            &pool,
            "SELECT COUNT(*) FROM poll_votes WHERE user_id = ?",
            voter.id
        )
        .await,
        1
    );

    store.delete_account(voter.id).await.unwrap();

    assert_eq!(
        count(
            &pool,
            "SELECT COUNT(*) FROM poll_votes WHERE user_id = ?",
            voter.id
        )
        .await,
        0,
        "a record of how a deleted account voted is personal data it left behind"
    );
}

/// Both directions. Their own list is plainly theirs; their id sitting in
/// somebody else's list is a reference to a person who no longer exists, and
/// a deleted account cannot come back to be blocked again.
#[tokio::test]
async fn deleting_an_account_takes_its_blocks_in_both_directions() {
    let (store, pool, _guard) = new_store().await;
    let admin = store
        .create_account("root", "Root", "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(admin.id).await.unwrap();

    let leaver = store
        .create_account("leaver", "Leaver", "not-a-real-hash")
        .await
        .unwrap();
    let other = store
        .create_account("other", "Other", "not-a-real-hash")
        .await
        .unwrap();
    store.block_user(leaver.id, other.id).await.unwrap();
    store.block_user(other.id, leaver.id).await.unwrap();

    store.delete_account(leaver.id).await.unwrap();

    assert_eq!(
        count(
            &pool,
            "SELECT COUNT(*) FROM user_blocks WHERE blocker_id = ? OR blocked_id = ?",
            leaver.id,
        )
        .await,
        0,
        "neither their own list nor their id in somebody else's survives"
    );
}

/// Per-channel notification settings are configuration about one account and
/// nobody else, the same class as `dm_hides` and `read_states`, both of which
/// were already purged.
#[tokio::test]
async fn deleting_an_account_takes_its_notification_preferences() {
    let (store, pool, _guard) = new_store().await;
    let admin = store
        .create_account("root", "Root", "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(admin.id).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;

    let leaver = store
        .create_account("leaver", "Leaver", "not-a-real-hash")
        .await
        .unwrap();
    store
        .set_channel_notification_preference(leaver.id, channel, NotificationPreference::Mentions)
        .await
        .unwrap();
    assert_eq!(
        count(
            &pool,
            "SELECT COUNT(*) FROM channel_notification_prefs WHERE user_id = ?",
            leaver.id,
        )
        .await,
        1
    );

    store.delete_account(leaver.id).await.unwrap();

    assert_eq!(
        count(
            &pool,
            "SELECT COUNT(*) FROM channel_notification_prefs WHERE user_id = ?",
            leaver.id,
        )
        .await,
        0
    );
}

/// A forward's snapshot is content other people can still see, so it keeps
/// its row and loses its author - the same treatment `messages.author_id`
/// gets, and for the same reason.
#[tokio::test]
async fn deleting_an_account_anonymizes_a_forward_of_its_messages() {
    let (store, pool, _guard) = new_store().await;
    let admin = store
        .create_account("root", "Root", "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(admin.id).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;

    let author = store
        .create_account("author", "Author", "not-a-real-hash")
        .await
        .unwrap();
    let original = MessageId::generate();
    store
        .send_message(NewMessage::plain(
            channel,
            author.id,
            original,
            "the original",
        ))
        .await
        .unwrap();
    let source = store.forward_source(original).await.unwrap().unwrap();
    store
        .send_message(NewMessage {
            channel_id: channel,
            author_id: admin.id,
            id: MessageId::generate(),
            content: "passing it on",
            attachment_ids: &[],
            reply_to_id: None,
            forward: Some(source.origin),
        })
        .await
        .unwrap();

    store.delete_account(author.id).await.unwrap();

    assert_eq!(
        count(
            &pool,
            "SELECT COUNT(*) FROM message_forwards WHERE origin_author_id = ?",
            author.id,
        )
        .await,
        0,
        "the id is cleared, exactly as messages.author_id is"
    );
    let kept: i64 = sqlx::query("SELECT COUNT(*) FROM message_forwards")
        .fetch_one(&pool)
        .await
        .unwrap()
        .get(0);
    assert_eq!(kept, 1, "and the forward itself stays, content and all");
}
