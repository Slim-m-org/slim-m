// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A thread reply must wake the thread's own audience, not the whole parent
//! channel: docs/IMPLIED-GAPS.md's first entry.
//!
//! The audience is derived entirely from rows that already exist -
//! `Store::thread_participants` - plus anyone the reply `@`-mentions, both
//! still bounded by the ordinary view-permission check. This file proves the
//! narrowing removes a genuine bystander without ever granting a view nobody
//! already had, and that blocking and the parent's own view permission still
//! reach into a thread the same way they reach into any other channel -
//! moved here from `threads.rs` since both are about push, not about a
//! thread's own identity as a channel.
//!
//! `thread_push_mention_case.rs` is a sibling: it covers a username match's
//! letter-case sensitivity specifically, split out once this file crossed
//! the 500-line hard limit.

use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ids::{ChannelId, DeviceId, MessageId, UserId};
use slimm_server::store::{NewMessage, PushRegistration, Sent, Store};

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

/// A plain message with a fresh id, which is every send in this file: these
/// tests are about who gets woken, never about the message itself.
async fn send(store: &Store, channel: ChannelId, author: UserId, body: &str) -> Sent {
    store
        .send_message(NewMessage::plain(
            channel,
            author,
            MessageId::generate(),
            body,
        ))
        .await
        .unwrap()
}

async fn account(store: &Store, username: &str) -> (UserId, DeviceId) {
    let account = store
        .create_account(username, username, "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    let session = store.open_session(account.id, "phone").await.unwrap();
    (account.id, session.device_id)
}

/// A reply's audience is the parent message's author plus everyone who has
/// already replied, checked from both directions in one run: a bystander who
/// only ever read the parent channel is excluded, and both real participants
/// are included, so a change that narrowed too far or not at all fails one
/// half or the other.
#[tokio::test]
async fn a_reply_wakes_only_the_parent_author_and_actual_repliers() {
    let (store, _guard) = new_store("slimm-thread-push-participants").await;
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

    // Alice opens the thread and bob replies; carol never touches it.
    let parent = send(&store, channel, alice, "root").await;
    let thread = store
        .open_thread(channel, parent.message.id)
        .await
        .unwrap()
        .channel;
    send(&store, thread.id, bob, "first reply").await;

    // A second reply from bob: alice (the parent author) must be woken, carol must not.
    let recipients = wake_recipients(&store, thread.id, bob, "again")
        .await
        .unwrap();
    assert!(
        recipients.contains(&alice),
        "the parent message's own author must be woken, got {recipients:?}"
    );
    assert!(
        !recipients.contains(&carol),
        "carol has never touched this thread and must not be woken, got {recipients:?}"
    );

    // Carol replying herself makes her a participant from here on.
    send(&store, thread.id, carol, "joining in").await;
    let recipients = wake_recipients(&store, thread.id, alice, "reply")
        .await
        .unwrap();
    assert!(
        recipients.contains(&bob) && recipients.contains(&carol),
        "both repliers must now be woken, got {recipients:?}"
    );
}

/// A thread nobody has replied to yet still wakes somebody: the parent
/// message's own author, derived with no reply ever having been sent, since
/// requiring at least one existing reply before the first one can wake
/// anybody would make the very first reply in a thread silent.
#[tokio::test]
async fn the_first_reply_in_an_empty_thread_still_wakes_the_parent_author() {
    let (store, _guard) = new_store("slimm-thread-push-first-reply").await;
    let (alice, alice_device) = account(&store, "alice").await;
    let (bob, bob_device) = account(&store, "bob").await;
    let channel = store.list_channels().await.unwrap()[0].id;

    store
        .register_push(
            alice,
            alice_device,
            PushRegistration {
                platform: "ios",
                push_token: "alice-token",
                voip_push_token: None,
                push_public_key: &KEY,
                include_content: Some(false),
                include_content_chosen: true,
            },
        )
        .await
        .unwrap();
    store
        .register_push(
            bob,
            bob_device,
            PushRegistration {
                platform: "ios",
                push_token: "bob-token",
                voip_push_token: None,
                push_public_key: &KEY,
                include_content: Some(false),
                include_content_chosen: true,
            },
        )
        .await
        .unwrap();

    let parent = send(&store, channel, alice, "root").await;
    let thread = store
        .open_thread(channel, parent.message.id)
        .await
        .unwrap()
        .channel;

    let recipients = wake_recipients(&store, thread.id, bob, "first")
        .await
        .unwrap();
    assert!(
        recipients.contains(&alice),
        "the parent author must be woken by the very first reply, got {recipients:?}"
    );
}

/// An `@`-mention cuts through the narrowing: a bystander named directly in
/// a reply is woken even though they have never posted in the thread,
/// exactly the exception `docs/IMPLIED-GAPS.md`'s first entry names.
#[tokio::test]
async fn a_mention_wakes_a_bystander_the_thread_would_otherwise_exclude() {
    let (store, _guard) = new_store("slimm-thread-push-mention").await;
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

    let parent = send(&store, channel, alice, "root").await;
    let thread = store
        .open_thread(channel, parent.message.id)
        .await
        .unwrap()
        .channel;
    send(&store, thread.id, bob, "first reply").await;

    let without_mention = wake_recipients(&store, thread.id, bob, "no mention here")
        .await
        .unwrap();
    assert!(
        !without_mention.contains(&carol),
        "carol is a bystander with no mention and must not be woken, got {without_mention:?}"
    );

    let with_mention = wake_recipients(&store, thread.id, bob, "hey @carol take a look")
        .await
        .unwrap();
    assert!(
        with_mention.contains(&carol),
        "a direct mention must cut through the narrowing, got {with_mention:?}"
    );
}

/// A mention of somebody who cannot view the parent channel at all must not
/// grant them one: the narrowing only ever removes from the permission-
/// checked set, never adds to it.
#[tokio::test]
async fn a_mention_never_reaches_somebody_without_view_permission() {
    use slimm_server::permissions::Permissions;

    let (store, _guard) = new_store("slimm-thread-push-mention-denied").await;
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

    store
        .set_member_overwrite(channel, carol, Permissions::NONE, Permissions::VIEW_CHANNEL)
        .await
        .unwrap();

    let parent = send(&store, channel, alice, "root").await;
    let thread = store
        .open_thread(channel, parent.message.id)
        .await
        .unwrap()
        .channel;

    let recipients = wake_recipients(&store, thread.id, bob, "hey @carol take a look")
        .await
        .unwrap();
    assert!(
        !recipients.contains(&carol),
        "carol cannot view the parent channel, so a mention must not reach her, got {recipients:?}"
    );
}

/// Blocking reaches into a thread exactly as it reaches into any other
/// channel, because `message_recipients` resolves push visibility through
/// `viewers_among`, which now inherits a thread's permissions from its
/// parent rather than evaluating the thread's own (nonexistent) overwrites.
/// Alice and carol both have to be real participants (having replied) for
/// this to be a meaningful test of blocking rather than of the thread
/// narrowing below: without a reply, `message_recipients` would already
/// exclude them and the assertion would pass for the wrong reason.
#[tokio::test]
async fn blocking_still_holds_inside_a_thread() {
    let (store, _guard) = new_store("slimm-threads-block").await;
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

    let parent = send(&store, channel, bob, "root").await;
    let thread = store
        .open_thread(channel, parent.message.id)
        .await
        .unwrap()
        .channel;
    send(&store, thread.id, alice, "hi").await;
    send(&store, thread.id, carol, "hi").await;

    let before = wake_recipients(&store, thread.id, bob, "reply")
        .await
        .unwrap();
    assert!(
        before.contains(&alice) && before.contains(&carol),
        "both replied, so both are woken before anyone is blocked, got {before:?}"
    );

    store.block_user(alice, bob).await.unwrap();

    let after = wake_recipients(&store, thread.id, bob, "reply")
        .await
        .unwrap();
    assert!(
        !after.contains(&alice),
        "alice blocked bob and must not be woken for a message in bob's thread"
    );
    assert!(
        after.contains(&carol),
        "carol did not block anyone and is unaffected"
    );
}

/// The batched push-fan-out path (`viewers_among`) has its own copy of the
/// overwrite evaluation `permissions_in_channel` uses, so it needs its own
/// proof that a view denial set on the parent reaches a thread: this is the
/// one blocking cannot stand in for, since blocking is filtered before
/// `viewers_among` is ever asked anything. Bob has to be a real thread
/// participant (having replied) for a denial to have anything to remove:
/// the thread narrowing below already excludes a non-participant regardless
/// of the overwrite, which would make this test pass for the wrong reason.
#[tokio::test]
async fn a_view_denial_on_the_parent_excludes_a_push_recipient_from_the_thread() {
    use slimm_server::permissions::Permissions;

    let (store, _guard) = new_store("slimm-threads-push-inherit").await;
    let (alice, alice_device) = account(&store, "alice").await;
    let (bob, bob_device) = account(&store, "bob").await;
    let channel = store.list_channels().await.unwrap()[0].id;

    store
        .register_push(
            alice,
            alice_device,
            PushRegistration {
                platform: "ios",
                push_token: "alice-token",
                voip_push_token: None,
                push_public_key: &KEY,
                include_content: Some(false),
                include_content_chosen: true,
            },
        )
        .await
        .unwrap();
    store
        .register_push(
            bob,
            bob_device,
            PushRegistration {
                platform: "ios",
                push_token: "bob-token",
                voip_push_token: None,
                push_public_key: &KEY,
                include_content: Some(false),
                include_content_chosen: true,
            },
        )
        .await
        .unwrap();

    let parent = send(&store, channel, alice, "root").await;
    let thread = store
        .open_thread(channel, parent.message.id)
        .await
        .unwrap()
        .channel;
    send(&store, thread.id, bob, "hi").await;

    let before = wake_recipients(&store, thread.id, alice, "reply")
        .await
        .unwrap();
    assert!(
        before.contains(&bob),
        "bob replied and can view before any overwrite, got {before:?}"
    );

    store
        .set_member_overwrite(channel, bob, Permissions::NONE, Permissions::VIEW_CHANNEL)
        .await
        .unwrap();

    let after = wake_recipients(&store, thread.id, alice, "reply")
        .await
        .unwrap();
    assert!(
        !after.contains(&bob),
        "a view denial on the parent must reach a push recipient check on the thread too"
    );
}
