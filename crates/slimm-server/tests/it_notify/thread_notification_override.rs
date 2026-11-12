// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A channel override (`tests/it_notify/channel_notification_prefs.rs`) must reach the
//! threads hanging off that channel: a thread has its own channel row, so a
//! preference lookup keyed on the message's own channel id finds no override
//! and falls back to the account default, which reads as a mute that stopped
//! working the moment somebody replied in a thread instead.

use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ids::{ChannelId, DeviceId, MessageId, UserId};
use slimm_server::notifications::NotificationPreference;
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

async fn account(store: &Store, username: &str) -> (UserId, DeviceId) {
    let account = store
        .create_account(username, username, "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    let session = store.open_session(account.id, "phone").await.unwrap();
    (account.id, session.device_id)
}

async fn register(store: &Store, user: UserId, device: DeviceId, token: &str) {
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

/// Alice opens a thread, so she is its audience by [`Store::thread_participants`];
/// bob replies. Alice muting the *parent* channel has to silence that reply,
/// or muting a channel is only muting the part of it that is not in a thread.
#[tokio::test]
async fn a_parent_channel_mute_silences_a_reply_in_its_thread() {
    let (store, _guard) = new_store("slimm-thread-notif-parent-mute").await;
    let (alice, alice_device) = account(&store, "alice").await;
    let (bob, bob_device) = account(&store, "bob").await;
    let channel = store.list_channels().await.unwrap()[0].id;
    register(&store, alice, alice_device, "alice-token").await;
    register(&store, bob, bob_device, "bob-token").await;

    let parent = send(&store, channel, alice, "root").await;
    let thread = store
        .open_thread(channel, parent.message.id)
        .await
        .unwrap()
        .channel;

    store
        .set_channel_notification_preference(alice, channel, NotificationPreference::Nothing)
        .await
        .unwrap();

    let recipients = wake_recipients(&store, thread.id, bob, "a reply")
        .await
        .unwrap();
    assert!(
        !recipients.contains(&alice),
        "alice muted the parent channel, so its thread must be silent too, got {recipients:?}"
    );
}

/// The same lookup, one preference milder: a mentions-only parent must drop an
/// ordinary reply in its thread and still wake for a real mention in one.
#[tokio::test]
async fn a_parent_mentions_only_override_still_wakes_for_a_mention_in_its_thread() {
    let (store, _guard) = new_store("slimm-thread-notif-parent-mentions").await;
    let (alice, alice_device) = account(&store, "alice").await;
    let (bob, bob_device) = account(&store, "bob").await;
    let channel = store.list_channels().await.unwrap()[0].id;
    register(&store, alice, alice_device, "alice-token").await;
    register(&store, bob, bob_device, "bob-token").await;

    let parent = send(&store, channel, alice, "root").await;
    let thread = store
        .open_thread(channel, parent.message.id)
        .await
        .unwrap()
        .channel;

    store
        .set_channel_notification_preference(alice, channel, NotificationPreference::Mentions)
        .await
        .unwrap();

    let plain = wake_recipients(&store, thread.id, bob, "a reply")
        .await
        .unwrap();
    assert!(
        !plain.contains(&alice),
        "mentions-only on the parent must drop a plain reply in its thread, got {plain:?}"
    );

    let mention = wake_recipients(&store, thread.id, bob, "hey @alice look")
        .await
        .unwrap();
    assert!(
        mention.contains(&alice),
        "a real mention in the thread must still wake her, got {mention:?}"
    );
}

/// The thread's own override is the more specific answer, so it still wins:
/// muting one noisy thread must not need the whole parent channel muted, and
/// the parent's own row must not overwrite it.
#[tokio::test]
async fn a_thread_own_override_still_beats_its_parent_channel() {
    let (store, _guard) = new_store("slimm-thread-notif-own-override").await;
    let (alice, alice_device) = account(&store, "alice").await;
    let (bob, bob_device) = account(&store, "bob").await;
    let channel = store.list_channels().await.unwrap()[0].id;
    register(&store, alice, alice_device, "alice-token").await;
    register(&store, bob, bob_device, "bob-token").await;

    let parent = send(&store, channel, alice, "root").await;
    let thread = store
        .open_thread(channel, parent.message.id)
        .await
        .unwrap()
        .channel;

    store
        .set_channel_notification_preference(alice, thread.id, NotificationPreference::Nothing)
        .await
        .unwrap();

    let recipients = wake_recipients(&store, thread.id, bob, "hey @alice look")
        .await
        .unwrap();
    assert!(
        !recipients.contains(&alice),
        "alice muted this thread itself, so not even a mention wakes her, got {recipients:?}"
    );
}
