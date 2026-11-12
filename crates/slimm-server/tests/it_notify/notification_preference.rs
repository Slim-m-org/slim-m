// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The account-wide notification preference (migration 0032): which messages
//! are worth waking a device for, enforced in
//! `push::recipients::message_recipients` - the same "read where the
//! audience is computed" choke point blocking already uses, never a filter a
//! client applies after a push has already landed.
//!
//! Mirrors the shape `tests/it_spaces/blocking_reach.rs` and
//! `tests/it_notify/thread_push_narrowing.rs` already use: drive `message_recipients`
//! directly against a real store, no relay involved.

use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ids::{DeviceId, MessageId, UserId};
use slimm_server::notifications::NotificationPreference;
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

/// A fresh account has never set a preference, and the default must not be a
/// silent behaviour change for every account that existed before this
/// feature: a plain message still wakes them exactly as it always did.
#[tokio::test]
async fn a_fresh_account_defaults_to_everything() {
    let (store, _guard) = new_store("slimm-notif-pref-default").await;
    let (alice, alice_device) = account(&store, "alice").await;
    let (bob, bob_device) = account(&store, "bob").await;
    let channel = store.list_channels().await.unwrap()[0].id;
    register(&store, alice, alice_device, "alice-token").await;
    register(&store, bob, bob_device, "bob-token").await;

    assert_eq!(
        store.notification_preference(bob).await.unwrap(),
        Some(NotificationPreference::Everything),
        "a preference nobody has ever set reads as the pre-feature default"
    );

    let recipients = wake_recipients(&store, channel, alice, "hello")
        .await
        .unwrap();
    assert!(
        recipients.contains(&bob),
        "everything is the default, so a plain message still wakes bob, got {recipients:?}"
    );
}

/// `mentions` drops a plain message but keeps a real mention, in the plain
/// (non-DM, non-thread) channel case this preference exists for.
#[tokio::test]
async fn mentions_only_skips_a_plain_message_but_catches_a_mention() {
    let (store, _guard) = new_store("slimm-notif-pref-mentions").await;
    let (alice, alice_device) = account(&store, "alice").await;
    let (bob, bob_device) = account(&store, "bob").await;
    let channel = store.list_channels().await.unwrap()[0].id;
    register(&store, alice, alice_device, "alice-token").await;
    register(&store, bob, bob_device, "bob-token").await;
    assert!(
        store
            .set_notification_preference(bob, NotificationPreference::Mentions)
            .await
            .unwrap()
    );

    let plain = wake_recipients(&store, channel, alice, "just chatting")
        .await
        .unwrap();
    assert!(
        !plain.contains(&bob),
        "bob asked for mentions only, and this names nobody, got {plain:?}"
    );

    let mention = wake_recipients(&store, channel, alice, "hey @bob look")
        .await
        .unwrap();
    assert!(
        mention.contains(&bob),
        "a real mention must still wake a mentions-only recipient, got {mention:?}"
    );
}

/// A DM always counts as a mention of the recipient specifically, under the
/// `mentions` tier: somebody messaging a DM is addressing the recipient
/// directly by definition, the reasoning `Store::channel_notifies_as_dm`
/// documents.
#[tokio::test]
async fn mentions_only_still_wakes_for_a_plain_dm() {
    let (store, _guard) = new_store("slimm-notif-pref-dm-mentions").await;
    let (alice, alice_device) = account(&store, "alice").await;
    let (bob, bob_device) = account(&store, "bob").await;
    register(&store, alice, alice_device, "alice-token").await;
    register(&store, bob, bob_device, "bob-token").await;
    assert!(
        store
            .set_notification_preference(bob, NotificationPreference::Mentions)
            .await
            .unwrap()
    );

    let dm = store.open_dm(alice, bob).await.unwrap();
    let recipients = wake_recipients(&store, dm.id, alice, "hi there")
        .await
        .unwrap();
    assert!(
        recipients.contains(&bob),
        "a DM addresses bob directly, so mentions-only must still wake him, got {recipients:?}"
    );
}

/// `nothing` is absolute: it silences a DM too, unlike `mentions`'s carve-out,
/// because it is the account's explicit "not waiting to be talked into an
/// exception" choice.
#[tokio::test]
async fn nothing_silences_even_a_dm() {
    let (store, _guard) = new_store("slimm-notif-pref-nothing-dm").await;
    let (alice, alice_device) = account(&store, "alice").await;
    let (bob, bob_device) = account(&store, "bob").await;
    register(&store, alice, alice_device, "alice-token").await;
    register(&store, bob, bob_device, "bob-token").await;
    assert!(
        store
            .set_notification_preference(bob, NotificationPreference::Nothing)
            .await
            .unwrap()
    );

    let dm = store.open_dm(alice, bob).await.unwrap();
    let recipients = wake_recipients(&store, dm.id, alice, "hi there")
        .await
        .unwrap();
    assert!(
        !recipients.contains(&bob),
        "nothing means nothing, including a DM, got {recipients:?}"
    );
}

/// `nothing` also silences an actual mention: the strongest tier, not just
/// the narrowest.
#[tokio::test]
async fn nothing_silences_even_a_direct_mention() {
    let (store, _guard) = new_store("slimm-notif-pref-nothing-mention").await;
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

    let recipients = wake_recipients(&store, channel, alice, "hey @bob look")
        .await
        .unwrap();
    assert!(
        !recipients.contains(&bob),
        "nothing overrides even a direct mention, got {recipients:?}"
    );
}

/// Blocking still wins regardless of the blocker's own preference: an
/// `everything` recipient who blocked the author is still not woken, the
/// property `tests/it_spaces/blocking_reach.rs` already covers for the pre-existing
/// filter, checked again here so this new filter cannot have reordered
/// around it.
#[tokio::test]
async fn blocking_still_wins_over_an_everything_preference() {
    let (store, _guard) = new_store("slimm-notif-pref-block").await;
    let (alice, alice_device) = account(&store, "alice").await;
    let (bob, bob_device) = account(&store, "bob").await;
    let channel = store.list_channels().await.unwrap()[0].id;
    register(&store, alice, alice_device, "alice-token").await;
    register(&store, bob, bob_device, "bob-token").await;

    assert_eq!(
        store.notification_preference(bob).await.unwrap(),
        Some(NotificationPreference::Everything),
        "bob left his preference at the default for this test to be meaningful"
    );
    store.block_user(bob, alice).await.unwrap();

    let recipients = wake_recipients(&store, channel, alice, "hello")
        .await
        .unwrap();
    assert!(
        !recipients.contains(&bob),
        "bob blocked alice, so everything must not override the block, got {recipients:?}"
    );
}

/// The preference filter runs entirely inside `message_recipients`, which is
/// pure and stateless; the debounce (`push.rs`'s `Debounce`) is only ever
/// consulted afterwards, in `deliver`, over whoever this function returned.
/// Proven here by interleaving three plain messages that must all exclude
/// bob with one mention that must not have been silently suppressed by
/// anything the earlier calls did - the shape a stateful debounce sitting
/// upstream of this filter, by mistake, would break.
#[tokio::test]
async fn repeated_exclusions_never_affect_a_later_qualifying_message() {
    let (store, _guard) = new_store("slimm-notif-pref-repeat").await;
    let (alice, alice_device) = account(&store, "alice").await;
    let (bob, bob_device) = account(&store, "bob").await;
    let channel = store.list_channels().await.unwrap()[0].id;
    register(&store, alice, alice_device, "alice-token").await;
    register(&store, bob, bob_device, "bob-token").await;
    assert!(
        store
            .set_notification_preference(bob, NotificationPreference::Mentions)
            .await
            .unwrap()
    );

    for n in 0..3 {
        let content = format!("plain {n}");
        let recipients = wake_recipients(&store, channel, alice, &content)
            .await
            .unwrap();
        assert!(
            !recipients.contains(&bob),
            "message {n} names nobody and must not wake bob, got {recipients:?}"
        );
    }

    let recipients = wake_recipients(&store, channel, alice, "hey @bob, for real")
        .await
        .unwrap();
    assert!(
        recipients.contains(&bob),
        "the earlier exclusions must not have suppressed this genuine mention, got {recipients:?}"
    );
}

/// `set_notification_preference` reads back through `notification_preference`
/// immediately, the same round trip `PUT /push/preference` and
/// `GET /push/preference` give a client.
#[tokio::test]
async fn set_notification_preference_persists_and_reads_back() {
    let (store, _guard) = new_store("slimm-notif-pref-persist").await;
    let (bob, _) = account(&store, "bob").await;

    assert!(
        store
            .set_notification_preference(bob, NotificationPreference::Nothing)
            .await
            .unwrap()
    );
    assert_eq!(
        store.notification_preference(bob).await.unwrap(),
        Some(NotificationPreference::Nothing)
    );
}

/// `channel_notifies_as_dm` resolves through a thread the same way
/// `permission_channel` resolves permissions: a further plain reply inside a
/// thread hung off a DM message must still count as a DM for a
/// mentions-only recipient. This is the exact bug shape CLAUDE.md's
/// "Moderation reaching only the channel kind it was written for" warns will
/// recur: a naive check of the thread's own `kind` (always `text`, never
/// `dm`, per `Store::open_thread`) would answer this wrong.
///
/// Bob has to be a real thread participant (having replied once) first, or
/// `narrow_for_thread`'s own audience narrowing would already exclude him
/// with nothing left for the DM resolution to prove: this test needs to
/// isolate the preference layer's DM check from the thread layer's
/// participant check, not conflate the two.
#[tokio::test]
async fn a_thread_hanging_off_a_dm_message_still_counts_as_a_dm() {
    let (store, _guard) = new_store("slimm-notif-pref-dm-thread").await;
    let (alice, alice_device) = account(&store, "alice").await;
    let (bob, bob_device) = account(&store, "bob").await;
    register(&store, alice, alice_device, "alice-token").await;
    register(&store, bob, bob_device, "bob-token").await;
    assert!(
        store
            .set_notification_preference(bob, NotificationPreference::Mentions)
            .await
            .unwrap()
    );

    let dm = store.open_dm(alice, bob).await.unwrap();
    let parent = store
        .send_message(NewMessage::plain(
            dm.id,
            alice,
            MessageId::generate(),
            "root",
        ))
        .await
        .unwrap();
    let thread = store
        .open_thread(dm.id, parent.message.id)
        .await
        .unwrap()
        .channel;
    store
        .send_message(NewMessage::plain(
            thread.id,
            bob,
            MessageId::generate(),
            "first reply",
        ))
        .await
        .unwrap();

    let recipients = wake_recipients(&store, thread.id, alice, "a plain second reply")
        .await
        .unwrap();
    assert!(
        recipients.contains(&bob),
        "a thread hung off a DM message still resolves to a DM, got {recipients:?}"
    );
}

/// An ordinary channel never counts as a DM for the `mentions` tier, so
/// `channel_notifies_as_dm` genuinely narrows rather than always answering
/// true.
#[tokio::test]
async fn an_ordinary_channel_does_not_notify_as_a_dm() {
    let (store, _guard) = new_store("slimm-notif-pref-not-dm").await;
    account(&store, "alice").await;
    let channel = store.list_channels().await.unwrap()[0].id;

    assert!(
        !store.channel_notifies_as_dm(channel).await.unwrap(),
        "the bootstrap channel is an ordinary text channel, not a DM"
    );
}
