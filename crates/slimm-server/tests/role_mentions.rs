// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `@[Role Name]`: a role mention, resolved in
//! `push::recipients::resolved_mentions` against `Store::roles_for_names`
//! and `Store::members_with_role`, gated on that role's own `mentionable`
//! flag or the author holding `Permissions::MENTION_EVERYONE`.
//!
//! Mirrors `tests/mention_everyone.rs`'s shape: drive `message_recipients`
//! directly against a real store, each recipient set to
//! `NotificationPreference::Mentions` so only a real mention shows up.

use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ids::{DeviceId, RoleId, UserId};
use slimm_server::notifications::NotificationPreference;
use slimm_server::permissions::Permissions;
use slimm_server::presence::PresenceTracker;
use slimm_server::store::RoleChanges;
use slimm_server::store::{PushRegistration, Store};

mod support;

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

async fn mentions_only(store: &Store, user: UserId) {
    assert!(
        store
            .set_notification_preference(user, NotificationPreference::Mentions)
            .await
            .unwrap()
    );
}

async fn grant_mention_everyone(store: &Store, user: UserId) {
    let role = store
        .create_role("pingers", Permissions::MENTION_EVERYONE, false)
        .await
        .unwrap();
    store.assign_role(user, role).await.unwrap();
}

/// Creates `name`, marks it mentionable when asked, and returns its id -
/// every role in these tests starts non-mentionable via `create_role`, so a
/// test that wants otherwise says so explicitly rather than relying on the
/// column default.
async fn role(store: &Store, name: &str, mentionable: bool) -> RoleId {
    let id = store
        .create_role(name, Permissions::NONE, false)
        .await
        .unwrap();
    if mentionable {
        store
            .update_role(
                id,
                RoleChanges {
                    mentionable: Some(true),
                    ..RoleChanges::default()
                },
            )
            .await
            .unwrap();
    }
    id
}

/// A role marked `mentionable` wakes its members for anyone, no permission
/// of the author's own required - the whole point of the flag existing
/// separately from `MENTION_EVERYONE`.
#[tokio::test]
async fn a_mentionable_role_wakes_its_members_with_no_special_permission() {
    let (store, _guard) = new_store("slimm-role-mentions-mentionable").await;
    let (alice, alice_device) = account(&store, "alice").await;
    let (bob, bob_device) = account(&store, "bob").await;
    let channel = store.list_channels().await.unwrap()[0].id;
    register(&store, alice, alice_device, "alice-token").await;
    register(&store, bob, bob_device, "bob-token").await;
    mentions_only(&store, bob).await;

    let core_team = role(&store, "Core Team", true).await;
    store.assign_role(bob, core_team).await.unwrap();

    let recipients = slimm_server::push::message_recipients(
        &store,
        channel,
        alice,
        "@[Core Team] stand-up in five",
        &PresenceTracker::new(),
    )
    .await
    .unwrap();

    assert!(
        recipients.contains(&bob),
        "bob holds the mentionable role, so this must wake him, got {recipients:?}"
    );
}

/// The mirror case: a role that was never opted in stays quiet for an author
/// with no special permission - typing the mention is not refused, it just
/// reaches nobody extra, the same forgiving shape `@everyone` has.
#[tokio::test]
async fn a_non_mentionable_role_wakes_nobody_for_an_ungranted_author() {
    let (store, _guard) = new_store("slimm-role-mentions-not-mentionable").await;
    // Bootstraps so alice is an ordinary member: an administrator would bypass the very check this proves absent.
    account(&store, "founder").await;
    let (alice, alice_device) = account(&store, "alice").await;
    let (bob, bob_device) = account(&store, "bob").await;
    let channel = store.list_channels().await.unwrap()[0].id;
    register(&store, alice, alice_device, "alice-token").await;
    register(&store, bob, bob_device, "bob-token").await;
    mentions_only(&store, bob).await;

    let quiet_role = role(&store, "Core Team", false).await;
    store.assign_role(bob, quiet_role).await.unwrap();

    let recipients = slimm_server::push::message_recipients(
        &store,
        channel,
        alice,
        "@[Core Team] stand-up in five",
        &PresenceTracker::new(),
    )
    .await
    .unwrap();

    assert!(
        !recipients.contains(&bob),
        "the role was never made mentionable, so this must read as a plain message, got {recipients:?}"
    );
}

/// `Permissions::MENTION_EVERYONE` overrides a role's own `mentionable`
/// flag, the same override it already gives `@everyone`/`@here`.
#[tokio::test]
async fn mention_everyone_overrides_a_non_mentionable_role() {
    let (store, _guard) = new_store("slimm-role-mentions-override").await;
    let (alice, alice_device) = account(&store, "alice").await;
    let (bob, bob_device) = account(&store, "bob").await;
    let channel = store.list_channels().await.unwrap()[0].id;
    register(&store, alice, alice_device, "alice-token").await;
    register(&store, bob, bob_device, "bob-token").await;
    mentions_only(&store, bob).await;
    grant_mention_everyone(&store, alice).await;

    let quiet_role = role(&store, "Core Team", false).await;
    store.assign_role(bob, quiet_role).await.unwrap();

    let recipients = slimm_server::push::message_recipients(
        &store,
        channel,
        alice,
        "@[Core Team] stand-up in five",
        &PresenceTracker::new(),
    )
    .await
    .unwrap();

    assert!(
        recipients.contains(&bob),
        "alice holds MENTION_EVERYONE, which must override the role's own flag, got {recipients:?}"
    );
}

/// Role name matching is case-insensitive, the same as a plain username
/// mention already is.
#[tokio::test]
async fn role_name_matching_is_case_insensitive() {
    let (store, _guard) = new_store("slimm-role-mentions-case").await;
    let (alice, alice_device) = account(&store, "alice").await;
    let (bob, bob_device) = account(&store, "bob").await;
    let channel = store.list_channels().await.unwrap()[0].id;
    register(&store, alice, alice_device, "alice-token").await;
    register(&store, bob, bob_device, "bob-token").await;
    mentions_only(&store, bob).await;

    let core_team = role(&store, "Core Team", true).await;
    store.assign_role(bob, core_team).await.unwrap();

    let recipients = slimm_server::push::message_recipients(
        &store,
        channel,
        alice,
        "@[core team] stand-up in five",
        &PresenceTracker::new(),
    )
    .await
    .unwrap();

    assert!(
        recipients.contains(&bob),
        "role names must match case-insensitively, got {recipients:?}"
    );
}

/// A role's own members list is not the same set as the message's viewers:
/// somebody who holds the role but cannot see this particular channel must
/// not be woken by a mention of it here.
#[tokio::test]
async fn a_role_mention_never_reaches_a_member_who_cannot_view_the_channel() {
    let (store, _guard) = new_store("slimm-role-mentions-view-scoped").await;
    let (alice, alice_device) = account(&store, "alice").await;
    let (bob, bob_device) = account(&store, "bob").await;
    register(&store, alice, alice_device, "alice-token").await;
    register(&store, bob, bob_device, "bob-token").await;
    mentions_only(&store, bob).await;

    // A private channel: @everyone is denied VIEW_CHANNEL and bob has no overwrite re-granting it.
    let private_channel = store.create_channel("secret", "text").await.unwrap().id;
    let everyone_id = store
        .list_roles()
        .await
        .unwrap()
        .into_iter()
        .find(|r| r.is_everyone)
        .unwrap()
        .id;
    store
        .set_role_overwrite(
            private_channel,
            everyone_id,
            Permissions::NONE,
            Permissions::VIEW_CHANNEL,
        )
        .await
        .unwrap();

    let core_team = role(&store, "Core Team", true).await;
    store.assign_role(bob, core_team).await.unwrap();

    let recipients = slimm_server::push::message_recipients(
        &store,
        private_channel,
        alice,
        "@[Core Team] stand-up in five",
        &PresenceTracker::new(),
    )
    .await
    .unwrap();

    assert!(
        !recipients.contains(&bob),
        "bob cannot view this channel, so the role mention must not reach him, got {recipients:?}"
    );
}

/// `@[everyone]` is the literal role name `roles_for_names` refuses to
/// match: the reserved `@everyone` word is the only path to that blast
/// radius, gated on `MENTION_EVERYONE` directly rather than on whatever an
/// `@everyone`-named role's own `mentionable` flag happens to be.
#[tokio::test]
async fn a_bracketed_mention_of_the_everyone_role_by_name_resolves_nothing() {
    let (store, _guard) = new_store("slimm-role-mentions-not-everyone").await;
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
        "@[everyone] stand-up in five",
        &PresenceTracker::new(),
    )
    .await
    .unwrap();

    assert!(
        !recipients.contains(&bob),
        "the bracketed form must never reach the @everyone role, got {recipients:?}"
    );
}
