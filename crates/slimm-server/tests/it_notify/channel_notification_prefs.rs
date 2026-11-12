// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A per-(user, channel) override of the account-wide notification
//! preference (migration 0044), enforced in
//! `push::recipients::narrow_for_notification_preference`: mutes one channel,
//! or narrows it to mentions only, while every other channel keeps following
//! the account default. Mirrors the shape `tests/it_notify/notification_preference.rs`
//! already uses for the account-wide layer this extends.

use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ids::{ChannelId, DeviceId, UserId};
use slimm_server::notifications::NotificationPreference;
use slimm_server::presence::PresenceTracker;
use slimm_server::store::{PushRegistration, Store};

use crate::support;
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

async fn second_channel(store: &Store) -> ChannelId {
    store.create_channel("second", "text").await.unwrap().id
}

/// A channel override wins over a more permissive account default: bob's
/// account is left at `everything`, and muting just this one channel still
/// silences an ordinary message in it.
#[tokio::test]
async fn a_channel_mute_silences_a_channel_the_account_default_would_allow() {
    let (store, _guard) = new_store("slimm-chan-notif-mute-beats-everything").await;
    let (alice, alice_device) = account(&store, "alice").await;
    let (bob, bob_device) = account(&store, "bob").await;
    let channel = store.list_channels().await.unwrap()[0].id;
    register(&store, alice, alice_device, "alice-token").await;
    register(&store, bob, bob_device, "bob-token").await;
    assert_eq!(
        store.notification_preference(bob).await.unwrap(),
        Some(NotificationPreference::Everything),
        "bob's account default must stay at the default for this test to be meaningful"
    );

    store
        .set_channel_notification_preference(bob, channel, NotificationPreference::Nothing)
        .await
        .unwrap();

    let recipients = slimm_server::push::message_recipients(
        &store,
        channel,
        alice,
        "hello",
        &PresenceTracker::new(),
    )
    .await
    .unwrap();
    assert!(
        !recipients.contains(&bob),
        "bob muted this channel, so an everything default must not override it, got {recipients:?}"
    );
}

/// The opposite direction: bob's account default is `nothing`, but he has
/// overridden this one channel to `mentions`, and a real mention in it still
/// wakes him despite the stricter account default.
#[tokio::test]
async fn a_mentions_override_wakes_for_a_mention_despite_a_nothing_account_default() {
    let (store, _guard) = new_store("slimm-chan-notif-mentions-beats-nothing").await;
    let (alice, alice_device) = account(&store, "alice").await;
    let (bob, bob_device) = account(&store, "bob").await;
    let channel = store.list_channels().await.unwrap()[0].id;
    register(&store, alice, alice_device, "alice-token").await;
    register(&store, bob, bob_device, "bob-token").await;
    assert!(
        store
            .set_notification_preference(bob, NotificationPreference::Nothing)
            .await
            .unwrap()
    );
    store
        .set_channel_notification_preference(bob, channel, NotificationPreference::Mentions)
        .await
        .unwrap();

    let plain = slimm_server::push::message_recipients(
        &store,
        channel,
        alice,
        "just chatting",
        &PresenceTracker::new(),
    )
    .await
    .unwrap();
    assert!(
        !plain.contains(&bob),
        "mentions-only still drops a plain message, got {plain:?}"
    );

    let mention = slimm_server::push::message_recipients(
        &store,
        channel,
        alice,
        "hey @bob look",
        &PresenceTracker::new(),
    )
    .await
    .unwrap();
    assert!(
        mention.contains(&bob),
        "the channel override must beat the stricter account default for a real mention, got {mention:?}"
    );
}

/// A channel with no override follows the account default, both ways: bob's
/// account default is `nothing` and he never touched this channel, so it
/// stays silent exactly as the account-wide test already covers - the
/// control that proves the override table is not always winning.
#[tokio::test]
async fn a_channel_with_no_override_follows_the_account_default() {
    let (store, _guard) = new_store("slimm-chan-notif-no-override-follows-default").await;
    let (alice, alice_device) = account(&store, "alice").await;
    let (bob, bob_device) = account(&store, "bob").await;
    let channel = store.list_channels().await.unwrap()[0].id;
    register(&store, alice, alice_device, "alice-token").await;
    register(&store, bob, bob_device, "bob-token").await;
    assert!(
        store
            .set_notification_preference(bob, NotificationPreference::Nothing)
            .await
            .unwrap()
    );

    let recipients = slimm_server::push::message_recipients(
        &store,
        channel,
        alice,
        "hello",
        &PresenceTracker::new(),
    )
    .await
    .unwrap();
    assert!(
        !recipients.contains(&bob),
        "with no channel override, the account default alone governs, got {recipients:?}"
    );
}

/// An override is scoped to the one channel it names, not to every channel
/// the account can see - muting the first channel must not touch the second.
#[tokio::test]
async fn a_mute_on_one_channel_does_not_reach_a_second() {
    let (store, _guard) = new_store("slimm-chan-notif-scoped-to-one-channel").await;
    let (alice, alice_device) = account(&store, "alice").await;
    let (bob, bob_device) = account(&store, "bob").await;
    let muted = store.list_channels().await.unwrap()[0].id;
    let other = second_channel(&store).await;
    register(&store, alice, alice_device, "alice-token").await;
    register(&store, bob, bob_device, "bob-token").await;
    store
        .set_channel_notification_preference(bob, muted, NotificationPreference::Nothing)
        .await
        .unwrap();

    let in_muted = slimm_server::push::message_recipients(
        &store,
        muted,
        alice,
        "hello",
        &PresenceTracker::new(),
    )
    .await
    .unwrap();
    assert!(
        !in_muted.contains(&bob),
        "the muted channel must stay silent"
    );

    let in_other = slimm_server::push::message_recipients(
        &store,
        other,
        alice,
        "hello",
        &PresenceTracker::new(),
    )
    .await
    .unwrap();
    assert!(
        in_other.contains(&bob),
        "an unrelated channel must still notify at the account default, got {in_other:?}"
    );
}

/// Clearing an override reverts a channel to the account default rather than
/// leaving it stuck at whatever the override last said.
#[tokio::test]
async fn clearing_an_override_reverts_to_the_account_default() {
    let (store, _guard) = new_store("slimm-chan-notif-clear-reverts").await;
    let (alice, alice_device) = account(&store, "alice").await;
    let (bob, bob_device) = account(&store, "bob").await;
    let channel = store.list_channels().await.unwrap()[0].id;
    register(&store, alice, alice_device, "alice-token").await;
    register(&store, bob, bob_device, "bob-token").await;
    store
        .set_channel_notification_preference(bob, channel, NotificationPreference::Nothing)
        .await
        .unwrap();
    let muted = slimm_server::push::message_recipients(
        &store,
        channel,
        alice,
        "hello",
        &PresenceTracker::new(),
    )
    .await
    .unwrap();
    assert!(!muted.contains(&bob));

    store
        .clear_channel_notification_preference(bob, channel)
        .await
        .unwrap();

    let unmuted = slimm_server::push::message_recipients(
        &store,
        channel,
        alice,
        "hello",
        &PresenceTracker::new(),
    )
    .await
    .unwrap();
    assert!(
        unmuted.contains(&bob),
        "clearing the override must restore the everything default, got {unmuted:?}"
    );
    assert_eq!(
        store
            .channel_notification_preference(bob, channel)
            .await
            .unwrap(),
        None,
        "a cleared override must read back as absent, not as everything"
    );
}

/// Blocking still wins regardless of any per-channel override: a mentions
/// override does not resurrect a blocked author's mention, the same property
/// `tests/it_notify/notification_preference.rs` already proves for the account-wide
/// layer, checked again here so this per-channel narrowing cannot have
/// reordered around it.
#[tokio::test]
async fn blocking_still_wins_over_a_mentions_override() {
    let (store, _guard) = new_store("slimm-chan-notif-block-beats-override").await;
    let (alice, alice_device) = account(&store, "alice").await;
    let (bob, bob_device) = account(&store, "bob").await;
    let channel = store.list_channels().await.unwrap()[0].id;
    register(&store, alice, alice_device, "alice-token").await;
    register(&store, bob, bob_device, "bob-token").await;
    store
        .set_channel_notification_preference(bob, channel, NotificationPreference::Mentions)
        .await
        .unwrap();
    store.block_user(bob, alice).await.unwrap();

    let recipients = slimm_server::push::message_recipients(
        &store,
        channel,
        alice,
        "hey @bob look",
        &PresenceTracker::new(),
    )
    .await
    .unwrap();
    assert!(
        !recipients.contains(&bob),
        "bob blocked alice, so a mentions override must not override the block, got {recipients:?}"
    );
}

/// `set_channel_notification_preference` reads back through
/// `channel_notification_preference` immediately, the round trip
/// `PUT`/`GET` on the HTTP layer give a client - and `list_channel_notification_preferences`
/// carries the same row for the caller's own settings screen.
#[tokio::test]
async fn set_channel_notification_preference_persists_and_reads_back() {
    let (store, _guard) = new_store("slimm-chan-notif-persist").await;
    let (bob, _) = account(&store, "bob").await;
    let channel = store.list_channels().await.unwrap()[0].id;

    store
        .set_channel_notification_preference(bob, channel, NotificationPreference::Mentions)
        .await
        .unwrap();
    assert_eq!(
        store
            .channel_notification_preference(bob, channel)
            .await
            .unwrap(),
        Some(NotificationPreference::Mentions)
    );
    let listed = store
        .list_channel_notification_preferences(bob)
        .await
        .unwrap();
    assert_eq!(listed, vec![(channel, NotificationPreference::Mentions)]);
}

/// Setting an override twice replaces it rather than erroring or leaving two
/// rows behind - the `ON CONFLICT` upsert this rests on.
#[tokio::test]
async fn setting_an_override_twice_replaces_it() {
    let (store, _guard) = new_store("slimm-chan-notif-upsert").await;
    let (bob, _) = account(&store, "bob").await;
    let channel = store.list_channels().await.unwrap()[0].id;

    store
        .set_channel_notification_preference(bob, channel, NotificationPreference::Mentions)
        .await
        .unwrap();
    store
        .set_channel_notification_preference(bob, channel, NotificationPreference::Nothing)
        .await
        .unwrap();

    let listed = store
        .list_channel_notification_preferences(bob)
        .await
        .unwrap();
    assert_eq!(
        listed,
        vec![(channel, NotificationPreference::Nothing)],
        "the second set must replace the first, not add a second row"
    );
}

/// Clearing an override that was never set is a no-op, not an error - a
/// client's own "unmute" affordance must be safe to press on an already
/// unmuted channel.
#[tokio::test]
async fn clearing_a_never_set_override_is_a_harmless_no_op() {
    let (store, _guard) = new_store("slimm-chan-notif-clear-noop").await;
    let (bob, _) = account(&store, "bob").await;
    let channel = store.list_channels().await.unwrap()[0].id;

    store
        .clear_channel_notification_preference(bob, channel)
        .await
        .unwrap();
    assert_eq!(
        store
            .channel_notification_preference(bob, channel)
            .await
            .unwrap(),
        None
    );
}
