// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `Store::create_channel`'s next-position query is the fifth copy of the
//! same predicate `list_channels`, `reorder_channels` and `delete_channel`'s
//! last-channel guard already carry, and it was missing the
//! `parent_message_id IS NULL` exclusion the other three have. Harmless
//! while a thread's own position stays at its schema default (0, and
//! nothing in the public API ever sets it otherwise), but a thread that
//! ends up with a non-zero position - the exact drift this file forces by
//! writing one directly - must still not be counted toward where the next
//! real channel lands.

use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ids::MessageId;
use slimm_server::store::{NewMessage, Store};

use crate::support;
async fn new_store(name: &str) -> (Store, String, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new(name);
    let config = Config {
        port: 0,
        database_path: path.clone(),
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool), path, guard)
}

#[tokio::test]
async fn a_thread_with_a_nonzero_position_does_not_inflate_the_next_real_channel() {
    let (store, path, _guard) = new_store("slimm-channel-position-threads").await;
    let account = store
        .create_account("admin", "admin", "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    let general = &store.list_channels().await.unwrap()[0];
    let sent = store
        .send_message(NewMessage::plain(
            general.id,
            account.id,
            MessageId::generate(),
            "start",
        ))
        .await
        .unwrap();
    let thread = store
        .open_thread(general.id, sent.message.id)
        .await
        .unwrap()
        .channel;

    // Nothing the public API sets a thread's position off its schema default today.
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let raw_pool = db::connect(&config).await.expect("second connection");
    sqlx::query!(
        "UPDATE channels SET position = 9999 WHERE id = ?",
        thread.id
    )
    .execute(&raw_pool)
    .await
    .unwrap();

    let second = store.create_channel("second", "text").await.unwrap();

    assert_eq!(
        second.position, 1,
        "general is at position 0, so the next real channel must land at 1 - \
         not 10000, which is what counting the thread's own position would give"
    );
}
