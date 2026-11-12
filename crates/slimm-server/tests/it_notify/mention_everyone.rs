// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `@everyone` and `@here`: two reserved mention words, resolved in
//! `push::recipients::resolved_mentions` rather than through
//! `Store::user_ids_for_usernames`, and only ever expanded once the author
//! holds `Permissions::MENTION_EVERYONE` in the message's own channel.
//!
//! Mirrors the shape `tests/it_notify/notification_preference.rs` already uses: drive
//! `message_recipients` directly against a real store, each recipient set to
//! `NotificationPreference::Mentions` so a plain message would wake nobody
//! and only a real (or reserved) mention shows up in the result.
//!
//! `MENTION_EVERYONE` is granted through a real, explicitly-created role
//! rather than by making the author an administrator: `ADMINISTRATOR`
//! bypasses the evaluator and would answer `has_permission` truthfully for
//! any bit at all, including one the code never actually checked, which
//! would make these tests pass even if the gate read the wrong constant.

use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ids::{DeviceId, UserId};
use slimm_server::notifications::NotificationPreference;
use slimm_server::permissions::Permissions;
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

/// Every recipient in these tests is `Mentions`-only, so the assertions are
/// clean: present means the message counted as a mention for them, absent
/// means it did not.
async fn mentions_only(store: &Store, user: UserId) {
    assert!(
        store
            .set_notification_preference(user, NotificationPreference::Mentions)
            .await
            .unwrap()
    );
}

/// Grants `MENTION_EVERYONE` to `user` through a real, freshly created role -
/// never the `is_everyone` base role, which every account in these tests
/// already holds and which must stay without the bit for the "no grant"
/// tests to mean anything.
async fn grant_mention_everyone(store: &Store, user: UserId) {
    let role = store
        .create_role("pingers", Permissions::MENTION_EVERYONE, false)
        .await
        .unwrap();
    store.assign_role(user, role).await.unwrap();
}

/// The first account bootstraps the deployment (see `account`'s own doc)
/// and is an administrator; every account here is a plain `@everyone`
/// member instead, so none of them holds `MENTION_EVERYONE` until this
/// grants it - the bootstrap's own admin role is never used in this file.
#[tokio::test]
async fn at_everyone_wakes_every_mentions_only_viewer_once_the_author_is_granted_the_bit() {
    let (store, _guard) = new_store("slimm-mention-everyone-granted").await;
    let (alice, alice_device) = account(&store, "alice").await;
    let (bob, bob_device) = account(&store, "bob").await;
    let (carol, carol_device) = account(&store, "carol").await;
    let channel = store.list_channels().await.unwrap()[0].id;
    register(&store, alice, alice_device, "alice-token").await;
    register(&store, bob, bob_device, "bob-token").await;
    register(&store, carol, carol_device, "carol-token").await;
    mentions_only(&store, bob).await;
    mentions_only(&store, carol).await;
    grant_mention_everyone(&store, alice).await;

    let recipients = slimm_server::push::message_recipients(
        &store,
        channel,
        alice,
        "@everyone stand-up in five",
        &PresenceTracker::new(),
    )
    .await
    .unwrap();

    assert!(
        recipients.contains(&bob) && recipients.contains(&carol),
        "both mentions-only viewers must be woken by a granted @everyone, got {recipients:?}"
    );
}

/// The mirror case: the same message, from an author nobody granted the bit
/// to. `@everyone` is still typeable - it renders as an ordinary, if inert,
/// word - it just reaches nobody a plain message would not have.
#[tokio::test]
async fn at_everyone_from_an_ungranted_author_wakes_nobody_extra() {
    let (store, _guard) = new_store("slimm-mention-everyone-ungranted").await;
    // Bootstraps the deployment so alice is an ordinary member, not the administrator the first account always becomes.
    account(&store, "founder").await;
    let (alice, alice_device) = account(&store, "alice").await;
    let (bob, bob_device) = account(&store, "bob").await;
    let channel = store.list_channels().await.unwrap()[0].id;
    register(&store, alice, alice_device, "alice-token").await;
    register(&store, bob, bob_device, "bob-token").await;
    mentions_only(&store, bob).await;

    let recipients = slimm_server::push::message_recipients(
        &store,
        channel,
        alice,
        "@everyone stand-up in five",
        &PresenceTracker::new(),
    )
    .await
    .unwrap();

    assert!(
        !recipients.contains(&bob),
        "alice was never granted MENTION_EVERYONE, so this must read as a plain message, got {recipients:?}"
    );
}

/// `@here` is the same grant, narrowed to whoever `PresenceTracker` reports
/// as currently connected - the one thing that tells the two words apart.
#[tokio::test]
async fn at_here_wakes_only_the_currently_connected_viewer() {
    let (store, _guard) = new_store("slimm-mention-here-connected").await;
    let (alice, alice_device) = account(&store, "alice").await;
    let (bob, bob_device) = account(&store, "bob").await;
    let (carol, carol_device) = account(&store, "carol").await;
    let channel = store.list_channels().await.unwrap()[0].id;
    register(&store, alice, alice_device, "alice-token").await;
    register(&store, bob, bob_device, "bob-token").await;
    register(&store, carol, carol_device, "carol-token").await;
    mentions_only(&store, bob).await;
    mentions_only(&store, carol).await;
    grant_mention_everyone(&store, alice).await;

    let presence = PresenceTracker::new();
    presence.connect(bob);

    let recipients = slimm_server::push::message_recipients(
        &store,
        channel,
        alice,
        "@here anyone around?",
        &presence,
    )
    .await
    .unwrap();

    assert!(
        recipients.contains(&bob),
        "bob is connected, so @here must count as a mention for him, got {recipients:?}"
    );
    assert!(
        !recipients.contains(&carol),
        "carol is not connected, so @here must not wake her, got {recipients:?}"
    );
}

/// An unregistered username genuinely spelled `@everyone` (no such account
/// can exist; see `tests/it_accounts/auth.rs`'s registration coverage) must not resolve
/// through the ordinary username table and silently answer empty instead of
/// going through the reserved-word path.
#[tokio::test]
async fn at_everyone_never_reaches_the_ordinary_username_lookup() {
    let (store, _guard) = new_store("slimm-mention-everyone-not-a-username").await;
    let (alice, alice_device) = account(&store, "alice").await;
    let channel = store.list_channels().await.unwrap()[0].id;
    register(&store, alice, alice_device, "alice-token").await;

    // No grant, nobody else registered for push: must not error resolving "everyone" as a real username.
    let recipients = slimm_server::push::message_recipients(
        &store,
        channel,
        alice,
        "@everyone",
        &PresenceTracker::new(),
    )
    .await
    .unwrap();

    assert!(recipients.is_empty());
}

/// A message that mentions a real person by name alongside `@everyone`
/// still resolves the real name, whether or not the author holds the bit -
/// the reserved words are pulled out of the mention set before it goes to
/// username resolution, never instead of it.
#[tokio::test]
async fn an_ordinary_mention_beside_at_everyone_still_resolves() {
    let (store, _guard) = new_store("slimm-mention-everyone-beside-real").await;
    let (alice, alice_device) = account(&store, "alice").await;
    let (bob, bob_device) = account(&store, "bob").await;
    let channel = store.list_channels().await.unwrap()[0].id;
    register(&store, alice, alice_device, "alice-token").await;
    register(&store, bob, bob_device, "bob-token").await;
    mentions_only(&store, bob).await;

    let recipients = slimm_server::push::message_recipients(
        &store,
        channel,
        alice,
        "@everyone but especially @bob",
        &PresenceTracker::new(),
    )
    .await
    .unwrap();

    assert!(
        recipients.contains(&bob),
        "the ordinary @bob mention must resolve regardless of the ungranted @everyone, got {recipients:?}"
    );
}
