// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The DM branch of `permissions_in_channels`, which answers a whole page of
//! DMs from one pair query and one pair of block reads instead of calling
//! `dm_permissions` per channel.
//!
//! Batching a check is only safe if it answers identically, and blocking is
//! the part with the most ways to go quietly wrong: it is directional, it
//! denies rather than hides, and a personal space is a DM whose other party is
//! the caller themself. Each case here is asserted against
//! `permissions_in_channel` rather than against a literal, so the two paths
//! cannot drift apart without this failing.

use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::permissions::{Permissions, mask_unless_viewable};
use slimm_server::store::Store;

use crate::support;
async fn store() -> (Store, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new("slimm-perm-dm-batch-test");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool), guard)
}

#[tokio::test]
async fn the_dm_batch_answers_every_blocking_shape_the_per_channel_check_does() {
    let (s, _guard) = store().await;
    let alice = s.create_user("alice", "Alice").await.unwrap();
    let bob = s.create_user("bob", "Bob").await.unwrap();
    let carol = s.create_user("carol", "Carol").await.unwrap();
    let dave = s.create_user("dave", "Dave").await.unwrap();
    let erin = s.create_user("erin", "Erin").await.unwrap();

    let plain = s.open_dm(alice.id, bob.id).await.unwrap();
    let alice_blocked = s.open_dm(alice.id, carol.id).await.unwrap();
    let blocked_alice = s.open_dm(alice.id, dave.id).await.unwrap();
    let personal = s.open_dm(alice.id, alice.id).await.unwrap();
    let not_hers = s.open_dm(dave.id, erin.id).await.unwrap();

    s.block_user(alice.id, carol.id).await.unwrap();
    s.block_user(dave.id, alice.id).await.unwrap();

    let ids = vec![
        plain.id,
        alice_blocked.id,
        blocked_alice.id,
        personal.id,
        not_hers.id,
    ];
    let batched = s.permissions_in_channels(alice.id, &ids).await.unwrap();

    for &id in &ids {
        let single = mask_unless_viewable(s.permissions_in_channel(alice.id, id).await.unwrap());
        assert_eq!(
            batched.get(&id).copied().unwrap_or(Permissions::NONE),
            single,
            "batched and per-channel answers diverged for {id:?}"
        );
    }

    // Spelled out too: both paths breaking together would agree at the wrong answer.
    assert!(
        batched[&plain.id].contains(Permissions::SEND_MESSAGES),
        "an unblocked DM may be written in"
    );
    assert!(
        !batched[&alice_blocked.id].contains(Permissions::SEND_MESSAGES),
        "blocking someone must stop the caller writing to them"
    );
    assert!(
        !batched[&blocked_alice.id].contains(Permissions::SEND_MESSAGES),
        "being blocked must stop the caller writing too - the deny is not directional"
    );
    assert!(
        batched[&alice_blocked.id].contains(Permissions::VIEW_CHANNEL),
        "a blocked DM stays readable; the block denies rather than hides"
    );
    assert!(
        batched[&personal.id].contains(Permissions::SEND_MESSAGES),
        "a personal space's other party is the caller, who has not blocked themself"
    );
    assert_eq!(
        batched[&not_hers.id],
        Permissions::NONE,
        "a DM the caller is not part of grants nothing"
    );
}

/// A DM channel row with no `dm_channels` pair behind it cannot be reached
/// through `open_dm`, so the batch is asked about one directly: the pair lookup
/// misses and the answer has to be NONE rather than the DM baseline.
#[tokio::test]
async fn a_dm_channel_with_no_pair_grants_nothing() {
    let (s, _guard) = store().await;
    let alice = s.create_user("alice", "Alice").await.unwrap();
    let orphan = s.create_channel("orphan", "dm").await.unwrap();

    let batched = s
        .permissions_in_channels(alice.id, &[orphan.id])
        .await
        .unwrap();
    assert_eq!(batched[&orphan.id], Permissions::NONE);
    assert_eq!(
        batched[&orphan.id],
        mask_unless_viewable(s.permissions_in_channel(alice.id, orphan.id).await.unwrap()),
        "and identically to the per-channel check"
    );
}
