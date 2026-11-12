// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Two places that acted on a channel scope without fully asserting it.
//!
//! `update_channel` excluded DMs and not threads, so a thread's own channel
//! could be renamed or given a topic - the recurring shape this project has
//! already been caught by twice, where a routine written against the channel
//! kinds that existed keeps running unrevisited once a new kind arrives.
//! `list_channels`, `reorder_channels` and `delete_channel`'s last-channel
//! count all exclude threads already; this was the one that did not.
//!
//! `list_pinned_messages` filtered pins by channel and then joined the message
//! without re-asserting the message belongs to that same channel. Not
//! reachable today, since `pin_message` is the only writer and it checks -
//! which is exactly why it is worth holding structurally, on a read that
//! returns whole message bodies.
//!
//! Its own file rather than added to `threads.rs`, which sits at 496 lines
//! against the 500-line ceiling.

use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ids::{ChannelId, MessageId};
use slimm_server::store::{NewMessage, Store};
use sqlx::SqlitePool;

use crate::support;
/// The pool is handed back alongside the store so a test can plant a row no
/// production path can create; `SqlitePool` is a cheap handle to clone.
async fn new_store(name: &str) -> (Store, SqlitePool, support::TestDbGuard) {
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

/// An admin, the bootstrap channel, and a thread opened on a message in it.
async fn thread_fixture(store: &Store) -> (ChannelId, ChannelId) {
    let admin = store
        .create_account("root", "Root", "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(admin.id).await.unwrap();
    let parent = store.list_channels().await.unwrap()[0].id;
    let message = store
        .send_message(NewMessage::plain(
            parent,
            admin.id,
            MessageId::generate(),
            "hi",
        ))
        .await
        .unwrap()
        .message
        .id;
    let thread = store.open_thread(parent, message).await.unwrap().channel.id;
    (parent, thread)
}

#[tokio::test]
async fn a_thread_channel_cannot_be_renamed() {
    let (store, _pool, _guard) = new_store("slimm-scope-rename").await;
    let (_parent, thread) = thread_fixture(&store).await;

    let updated = store
        .update_channel(thread, Some("renamed"), None)
        .await
        .unwrap();
    assert!(
        updated.is_none(),
        "renaming a thread's own channel must not be accepted"
    );
    assert_eq!(
        store.channel(thread).await.unwrap().unwrap().name,
        "",
        "a thread's name must still be the empty one it was opened with"
    );
}

#[tokio::test]
async fn a_thread_channel_cannot_be_given_a_topic() {
    let (store, _pool, _guard) = new_store("slimm-scope-topic").await;
    let (_parent, thread) = thread_fixture(&store).await;

    let updated = store
        .update_channel(thread, None, Some(Some("a topic")))
        .await
        .unwrap();
    assert!(updated.is_none(), "a thread must not take a topic");
    assert!(
        store
            .channel(thread)
            .await
            .unwrap()
            .unwrap()
            .topic
            .is_none(),
        "the thread's topic must still be unset"
    );
}

/// The regression guard for the obvious over-correction.
///
/// Excluding threads from `update_channel` invites doing the same to
/// `delete_channel`, and that would be wrong: `docs/decisions/0005-threads.md`
/// and CLAUDE.md both record that the generic `DELETE /channels/{id}` is
/// deliberately how a thread gets deleted, with the last-channel guard already
/// indifferent to it. This fails if that filter is ever copied across.
#[tokio::test]
async fn a_thread_can_still_be_deleted() {
    let (store, _pool, _guard) = new_store("slimm-scope-delete").await;
    let (_parent, thread) = thread_fixture(&store).await;

    assert!(
        store.delete_channel(thread).await.unwrap(),
        "deleting a thread through the generic route must keep working"
    );
}

/// An ordinary channel is unaffected by the thread exclusion.
#[tokio::test]
async fn an_ordinary_channel_still_renames() {
    let (store, _pool, _guard) = new_store("slimm-scope-ordinary").await;
    let (parent, _thread) = thread_fixture(&store).await;

    let updated = store
        .update_channel(parent, Some("general-2"), None)
        .await
        .unwrap();
    assert_eq!(
        updated.map(|c| c.name),
        Some("general-2".to_owned()),
        "a real channel must still be renameable, or this suite would pass \
         with the whole verb broken"
    );
}

/// A pin row pointing at a message in another channel is not returned.
///
/// Planted with raw SQL, since no production path can create one: the point is
/// that the read refuses it structurally rather than trusting the writer.
#[tokio::test]
async fn a_pin_naming_another_channels_message_is_not_returned() {
    let (store, pool, _guard) = new_store("slimm-scope-pins").await;
    let admin = store
        .create_account("root", "Root", "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(admin.id).await.unwrap();
    let here = store.list_channels().await.unwrap()[0].id;
    let elsewhere = store.create_channel("secret", "text").await.unwrap().id;

    let foreign = store
        .send_message(NewMessage::plain(
            elsewhere,
            admin.id,
            MessageId::generate(),
            "not for here",
        ))
        .await
        .unwrap()
        .message
        .id;

    let now = 1_700_000_000_000i64;
    sqlx::query(
        "INSERT INTO pinned_messages (channel_id, message_id, pinned_by, pinned_at)
         VALUES (?, ?, ?, ?)",
    )
    .bind(here)
    .bind(foreign)
    .bind(admin.id)
    .bind(now)
    .execute(&pool)
    .await
    .expect("plant a cross-channel pin row");

    let pins = store.list_pinned_messages(here).await.unwrap();
    assert!(
        pins.is_empty(),
        "a pin naming another channel's message must not surface here: {pins:?}"
    );
}
