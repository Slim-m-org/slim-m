// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The two halves of blocking a client cannot do for itself.
//!
//! Blocking is one viewer's view choice, and hiding a blocked author's messages
//! belongs on the client: keeping them in the local database and filtering at
//! read time is what makes unblocking instant, where dropping them from `/sync`
//! would mean they never arrive again.
//!
//! Two surfaces are out of the client's reach entirely, and both are covered
//! here. A reaction crosses the wire as a count with no reactor ids, by design,
//! so there is nothing for a client-side filter to match on. And a push
//! notification is on the device before any filter runs, which makes it the
//! loudest possible way to be told exactly when the person you blocked spoke.

use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ids::{DeviceId, MessageId, UserId};
use slimm_server::store::{NewMessage, PushRegistration, Store};

use crate::support;
use support::wake_recipients;

const KEY: [u8; 32] = [7u8; 32];

async fn new_store(name: &str) -> (Store, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new(name);
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool), guard)
}

/// An account with a session, and the deployment claimed by the first one.
async fn account(store: &Store, username: &str) -> (UserId, DeviceId) {
    let account = store
        .create_account(username, username, "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    let session = store.open_session(account.id, "phone").await.unwrap();
    (account.id, session.device_id)
}

/// A reaction from a blocked user is not counted, and an emoji only they used is
/// absent from the row rather than sitting at zero.
///
/// Asserted from both sides in the same run: the same message, read by the
/// blocker and by somebody else, must not agree. A test that only read the
/// blocker's side would pass just as well against a server that dropped the
/// reaction for everybody, which is the moderation action this deliberately is
/// not.
#[tokio::test]
async fn a_blocked_users_reaction_is_not_counted_for_the_blocker_alone() {
    let (store, _guard) = new_store("slimm-block-reactions").await;
    let (alice, _) = account(&store, "alice").await;
    let (bob, _) = account(&store, "bob").await;
    let (carol, _) = account(&store, "carol").await;
    let channel = store.list_channels().await.unwrap()[0].id;

    let message = store
        .send_message(NewMessage::plain(
            channel,
            alice,
            MessageId::generate(),
            "hello",
        ))
        .await
        .unwrap();

    store
        .add_reaction(message.message.id, bob, "wave")
        .await
        .unwrap();
    store
        .add_reaction(message.message.id, carol, "wave")
        .await
        .unwrap();
    store
        .add_reaction(message.message.id, bob, "tada")
        .await
        .unwrap();

    let before = store
        .reactions_for_message(message.message.id, alice)
        .await
        .unwrap();
    assert_eq!(before.len(), 2, "two emoji before anyone is blocked");
    assert_eq!(before.iter().find(|r| r.emoji == "wave").unwrap().count, 2);

    store.block_user(alice, bob).await.unwrap();

    let after = store
        .reactions_for_message(message.message.id, alice)
        .await
        .unwrap();
    assert_eq!(
        after.len(),
        1,
        "the emoji only the blocked user used must be gone, not zero"
    );
    let wave = after.iter().find(|r| r.emoji == "wave").unwrap();
    assert_eq!(wave.count, 1, "only carol is counted now");

    let carols_view = store
        .reactions_for_message(message.message.id, carol)
        .await
        .unwrap();
    assert_eq!(
        carols_view.len(),
        2,
        "nothing was removed; this is one viewer's view, not moderation"
    );
}

/// Blocking yourself is refused, so the `reacted` flag cannot be filtered out
/// from under the person reading it: a viewer is never in their own block list.
#[tokio::test]
async fn a_viewers_own_reaction_survives_the_filter() {
    let (store, _guard) = new_store("slimm-block-own-reaction").await;
    let (alice, _) = account(&store, "alice").await;
    let (bob, _) = account(&store, "bob").await;
    let channel = store.list_channels().await.unwrap()[0].id;

    let message = store
        .send_message(NewMessage::plain(
            channel,
            bob,
            MessageId::generate(),
            "hello",
        ))
        .await
        .unwrap();
    store
        .add_reaction(message.message.id, alice, "wave")
        .await
        .unwrap();
    store.block_user(alice, bob).await.unwrap();

    let mine = store
        .reactions_for_message(message.message.id, alice)
        .await
        .unwrap();
    assert_eq!(mine.len(), 1);
    assert!(mine[0].reacted, "the viewer's own reaction is still theirs");
    assert_eq!(mine[0].count, 1);
}

/// The reverse lookup push fan-out needs. `blocked_users` answers "who did this
/// member block"; this answers "who blocked them", which is the direction a
/// message's author is asked about.
#[tokio::test]
async fn blockers_of_reads_the_other_direction() {
    let (store, _guard) = new_store("slimm-block-reverse").await;
    let (alice, _) = account(&store, "alice").await;
    let (bob, _) = account(&store, "bob").await;
    let (carol, _) = account(&store, "carol").await;

    store.block_user(alice, bob).await.unwrap();
    store.block_user(carol, bob).await.unwrap();
    store.block_user(bob, carol).await.unwrap();

    let blockers = store.blockers_of(bob).await.unwrap();
    assert_eq!(blockers.len(), 2);
    assert!(blockers.contains(&alice) && blockers.contains(&carol));

    assert_eq!(
        store.blockers_of(alice).await.unwrap(),
        Vec::new(),
        "nobody blocked alice, and their own block of bob is the other direction"
    );
}

/// A blocker with a live push registration and full view permission is still
/// not woken for the author they blocked, while everybody else is.
#[tokio::test]
async fn a_blocker_is_not_a_push_recipient_for_the_author_they_blocked() {
    let (store, _guard) = new_store("slimm-block-push").await;
    let (alice, alice_device) = account(&store, "alice").await;
    let (bob, bob_device) = account(&store, "bob").await;
    let (carol, carol_device) = account(&store, "carol").await;
    let channel = store.list_channels().await.unwrap()[0].id;

    for (user, device, token) in [
        (alice, alice_device, "alice-token"),
        (bob, bob_device, "bob-token"),
        (carol, carol_device, "carol-token"),
    ] {
        store
            .register_push(
                user,
                device,
                PushRegistration {
                    platform: "ios",
                    push_token: token,
                    voip_push_token: None,
                    push_public_key: &KEY,
                    include_content: Some(false),
                    include_content_chosen: true,
                },
            )
            .await
            .unwrap();
    }

    let before = wake_recipients(&store, channel, bob, "hello")
        .await
        .unwrap();
    assert!(
        before.contains(&alice) && before.contains(&carol),
        "both would be woken before anyone is blocked, got {before:?}"
    );
    assert!(
        !before.contains(&bob),
        "an author is never woken for their own message"
    );

    store.block_user(alice, bob).await.unwrap();

    let after = wake_recipients(&store, channel, bob, "hello")
        .await
        .unwrap();
    assert!(
        !after.contains(&alice),
        "alice blocked bob and must not be woken for them"
    );
    assert!(
        after.contains(&carol),
        "carol did not block anyone and is unaffected"
    );

    let reverse = wake_recipients(&store, channel, alice, "hello")
        .await
        .unwrap();
    assert!(
        reverse.contains(&bob),
        "blocking is one-directional: bob never blocked alice and still hears from them"
    );
}
