// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! An overwrite applies to its target and nobody else, on both batched paths.
//!
//! `permissions.rs` proves the batched evaluators agree with the per-user
//! check across every rule, but every overwrite in those fixtures targets
//! someone who is being evaluated. cargo-mutants showed what that leaves
//! open: replacing the guards that match an overwrite to the everyone role,
//! to a role the user holds, or to the user themself with `true` survived the
//! suite - so a deny aimed at a role a member does not hold could have been
//! applied to them without a test noticing. These fixtures always include a
//! bystander the overwrite must not touch.

use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;

use crate::support;
const VIEW: Permissions = Permissions::VIEW_CHANNEL;
const SEND: Permissions = Permissions::SEND_MESSAGES;
const NONE: Permissions = Permissions::NONE;

async fn store() -> (Store, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new("slimm-perm-targets");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool), guard)
}

/// Both batched answers and the per-user check for one member in one channel.
async fn can_view(
    s: &Store,
    user: slimm_server::ids::UserId,
    channel: slimm_server::ids::ChannelId,
) -> (bool, bool, bool) {
    let single = s.has_permission(user, channel, VIEW).await.unwrap();
    let among = s
        .viewers_among(channel, &[user])
        .await
        .unwrap()
        .contains(&user);
    let batched =
        s.permissions_in_channels(user, &[channel]).await.unwrap()[&channel].contains(VIEW);
    (single, among, batched)
}

#[tokio::test]
async fn a_role_overwrite_reaches_only_members_who_hold_that_role() {
    let (s, _guard) = store().await;
    s.create_role("everyone", VIEW.union(SEND), true)
        .await
        .unwrap();
    let mods = s.create_role("mods", NONE, false).await.unwrap();
    let alice = s.create_user("alice", "Alice").await.unwrap();
    let bob = s.create_user("bob", "Bob").await.unwrap();
    s.assign_role(bob.id, mods).await.unwrap();
    let channel = s.create_channel("general", "text").await.unwrap();

    // A deny aimed at mods, which alice is not.
    s.set_role_overwrite(channel.id, mods, NONE, VIEW)
        .await
        .unwrap();

    assert_eq!(
        can_view(&s, alice.id, channel.id).await,
        (true, true, true),
        "a bystander keeps VIEW on every path"
    );
    assert_eq!(
        can_view(&s, bob.id, channel.id).await,
        (false, false, false),
        "the role's holder loses it on every path"
    );
    assert_eq!(
        s.viewers_among(channel.id, &[alice.id, bob.id])
            .await
            .unwrap(),
        vec![alice.id]
    );
}

#[tokio::test]
async fn a_member_overwrite_reaches_only_that_member() {
    let (s, _guard) = store().await;
    s.create_role("everyone", VIEW.union(SEND), true)
        .await
        .unwrap();
    let alice = s.create_user("alice", "Alice").await.unwrap();
    let bob = s.create_user("bob", "Bob").await.unwrap();
    let channel = s.create_channel("general", "text").await.unwrap();

    s.set_member_overwrite(channel.id, bob.id, NONE, VIEW)
        .await
        .unwrap();

    assert_eq!(can_view(&s, alice.id, channel.id).await, (true, true, true));
    assert_eq!(
        can_view(&s, bob.id, channel.id).await,
        (false, false, false)
    );
}

/// The everyone role's overwrite is the one that applies to a member with no
/// roles at all; an overwrite on any other role must not be mistaken for it.
#[tokio::test]
async fn only_the_everyone_roles_overwrite_reaches_a_member_with_no_roles() {
    let (s, _guard) = store().await;
    let everyone = s.create_role("everyone", SEND, true).await.unwrap();
    let mods = s.create_role("mods", NONE, false).await.unwrap();
    let alice = s.create_user("alice", "Alice").await.unwrap();
    let channel = s.create_channel("general", "text").await.unwrap();

    // The mods overwrite would grant VIEW; alice holds no roles, so it is not hers.
    s.set_role_overwrite(channel.id, mods, VIEW, NONE)
        .await
        .unwrap();
    assert_eq!(
        can_view(&s, alice.id, channel.id).await,
        (false, false, false),
        "a grant on a role she does not hold is not hers"
    );

    s.set_role_overwrite(channel.id, everyone, VIEW, NONE)
        .await
        .unwrap();
    assert_eq!(
        can_view(&s, alice.id, channel.id).await,
        (true, true, true),
        "the everyone role's grant is"
    );
}

#[tokio::test]
async fn clearing_a_member_overwrite_restores_the_evaluation() {
    let (s, _guard) = store().await;
    s.create_role("everyone", VIEW.union(SEND), true)
        .await
        .unwrap();
    let alice = s.create_user("alice", "Alice").await.unwrap();
    let channel = s.create_channel("general", "text").await.unwrap();

    s.set_member_overwrite(channel.id, alice.id, NONE, VIEW)
        .await
        .unwrap();
    assert_eq!(
        can_view(&s, alice.id, channel.id).await,
        (false, false, false)
    );

    s.delete_member_overwrite(channel.id, alice.id)
        .await
        .unwrap();
    assert_eq!(
        can_view(&s, alice.id, channel.id).await,
        (true, true, true),
        "a cleared overwrite must stop applying, not merely stop being listed"
    );
    // Clearing what is already clear is a no-op, not an error.
    s.delete_member_overwrite(channel.id, alice.id)
        .await
        .unwrap();
}
