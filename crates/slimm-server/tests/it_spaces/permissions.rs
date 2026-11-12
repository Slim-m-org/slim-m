// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Integration tests for the permission evaluator against a real db, exercising
//! the load-and-evaluate path and the precedence rules end to end.

use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::permissions::Permissions;
use slimm_server::store::{NewMessage, Store};

use crate::support;
async fn store() -> (Store, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new("slimm-perm-test");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool), guard)
}

const VIEW: Permissions = Permissions::VIEW_CHANNEL;
const SEND: Permissions = Permissions::SEND_MESSAGES;
const NONE: Permissions = Permissions::NONE;

#[tokio::test]
async fn deny_by_default_with_no_roles() {
    let (s, _guard) = store().await;
    let user = s.create_user("nia", "Nia").await.unwrap();
    let channel = s.create_channel("general", "text").await.unwrap();

    let perms = s.permissions_in_channel(user.id, channel.id).await.unwrap();
    assert_eq!(perms, NONE);
    assert!(!s.has_permission(user.id, channel.id, SEND).await.unwrap());
}

#[tokio::test]
async fn everyone_base_applies_without_explicit_assignment() {
    let (s, _guard) = store().await;
    let user = s.create_user("omar", "Omar").await.unwrap();
    let channel = s.create_channel("general", "text").await.unwrap();
    s.create_role("everyone", VIEW.union(SEND), true)
        .await
        .unwrap();

    // The user holds no explicit role, but @everyone applies to all members.
    let perms = s.permissions_in_channel(user.id, channel.id).await.unwrap();
    assert!(perms.contains(VIEW));
    assert!(perms.contains(SEND));
}

#[tokio::test]
async fn explicit_role_unions_onto_the_base() {
    let (s, _guard) = store().await;
    let user = s.create_user("pia", "Pia").await.unwrap();
    let channel = s.create_channel("general", "text").await.unwrap();
    s.create_role("everyone", VIEW.union(SEND), true)
        .await
        .unwrap();
    let mods = s
        .create_role("mods", Permissions::MANAGE_MESSAGES, false)
        .await
        .unwrap();
    s.assign_role(user.id, mods).await.unwrap();

    let perms = s.permissions_in_channel(user.id, channel.id).await.unwrap();
    assert!(perms.contains(VIEW));
    assert!(perms.contains(Permissions::MANAGE_MESSAGES));
    // base_permissions ignores channels but should agree on the role union.
    let base = s.base_permissions(user.id).await.unwrap();
    assert!(base.contains(Permissions::MANAGE_MESSAGES));
}

#[tokio::test]
async fn administrator_bypasses_channel_denies() {
    let (s, _guard) = store().await;
    let user = s.create_user("quinn", "Quinn").await.unwrap();
    let channel = s.create_channel("general", "text").await.unwrap();
    let everyone = s.create_role("everyone", NONE, true).await.unwrap();
    let admins = s
        .create_role("admins", Permissions::ADMINISTRATOR, false)
        .await
        .unwrap();
    s.assign_role(user.id, admins).await.unwrap();
    // A channel deny on @everyone must not touch an administrator.
    s.set_role_overwrite(channel.id, everyone, NONE, Permissions::ALL)
        .await
        .unwrap();

    let perms = s.permissions_in_channel(user.id, channel.id).await.unwrap();
    assert_eq!(perms, Permissions::ALL);
    assert!(
        s.has_permission(user.id, channel.id, Permissions::BAN_MEMBERS)
            .await
            .unwrap()
    );
}

#[tokio::test]
async fn everyone_channel_overwrite_removes_a_base_permission() {
    let (s, _guard) = store().await;
    let user = s.create_user("rae", "Rae").await.unwrap();
    let channel = s.create_channel("general", "text").await.unwrap();
    let everyone = s
        .create_role("everyone", VIEW.union(SEND), true)
        .await
        .unwrap();
    s.set_role_overwrite(channel.id, everyone, NONE, SEND)
        .await
        .unwrap();

    // In this channel SEND is denied, but the guild base still carries it.
    let perms = s.permissions_in_channel(user.id, channel.id).await.unwrap();
    assert!(perms.contains(VIEW));
    assert!(!perms.contains(SEND));
    assert!(s.base_permissions(user.id).await.unwrap().contains(SEND));
}

#[tokio::test]
async fn role_overwrite_deny_wins_then_member_overwrite_regrants() {
    let (s, _guard) = store().await;
    let user = s.create_user("sol", "Sol").await.unwrap();
    let channel = s.create_channel("general", "text").await.unwrap();
    s.create_role("everyone", VIEW, true).await.unwrap();
    let a = s.create_role("a", NONE, false).await.unwrap();
    let b = s.create_role("b", NONE, false).await.unwrap();
    s.assign_role(user.id, a).await.unwrap();
    s.assign_role(user.id, b).await.unwrap();
    // Role a allows SEND in the channel, role b denies it. Deny wins.
    s.set_role_overwrite(channel.id, a, SEND, NONE)
        .await
        .unwrap();
    s.set_role_overwrite(channel.id, b, NONE, SEND)
        .await
        .unwrap();

    assert!(!s.has_permission(user.id, channel.id, SEND).await.unwrap());

    // A member overwrite grants it back absolutely.
    s.set_member_overwrite(channel.id, user.id, SEND, NONE)
        .await
        .unwrap();
    assert!(s.has_permission(user.id, channel.id, SEND).await.unwrap());
}

#[tokio::test]
async fn only_one_everyone_role_is_allowed() {
    let (s, _guard) = store().await;
    s.create_role("everyone", VIEW, true).await.unwrap();
    // A second @everyone role is rejected by the database constraint.
    assert!(
        s.create_role("everyone-again", SEND, true).await.is_err(),
        "a second @everyone role must be rejected"
    );
    // Ordinary roles are unaffected.
    assert!(s.create_role("mods", SEND, false).await.is_ok());
}

#[tokio::test]
async fn overwrites_for_other_targets_are_ignored() {
    let (s, _guard) = store().await;
    let user = s.create_user("tam", "Tam").await.unwrap();
    let other = s.create_user("uma", "Uma").await.unwrap();
    let channel = s.create_channel("general", "text").await.unwrap();
    s.create_role("everyone", VIEW.union(SEND), true)
        .await
        .unwrap();
    // A role the user does not hold, and a member overwrite for someone else.
    // Neither should touch this user's result.
    let ghost = s.create_role("ghost", NONE, false).await.unwrap();
    s.set_role_overwrite(channel.id, ghost, NONE, SEND)
        .await
        .unwrap();
    s.set_member_overwrite(channel.id, other.id, NONE, SEND)
        .await
        .unwrap();

    let perms = s.permissions_in_channel(user.id, channel.id).await.unwrap();
    assert!(perms.contains(SEND), "another target's deny must not apply");
}

/// The batched fan-out check must be indistinguishable from asking
/// [`Store::has_permission`] per candidate, across every rule the evaluator
/// has: base deny, role grant, role-overwrite deny, member-overwrite regrant,
/// the ADMINISTRATOR bypass, a DM's membership-only model, and a channel that
/// does not exist. Push fan-out rides on this equivalence; a divergence here
/// is a wrongly delivered (or wrongly suppressed) notification.
#[tokio::test]
async fn viewers_among_matches_the_per_user_check() {
    let (s, _guard) = store().await;
    s.create_role("everyone", NONE, true).await.unwrap();
    let viewer_role = s.create_role("viewer", VIEW, false).await.unwrap();
    let admin_role = s
        .create_role("admin", Permissions::ADMINISTRATOR, false)
        .await
        .unwrap();

    let plain = s.create_user("plain", "Plain").await.unwrap();
    let viewer = s.create_user("viewer", "Viewer").await.unwrap();
    let denied = s.create_user("denied", "Denied").await.unwrap();
    let regranted = s.create_user("regranted", "Regranted").await.unwrap();
    let admin = s.create_user("admin", "Admin").await.unwrap();
    s.assign_role(viewer.id, viewer_role).await.unwrap();
    s.assign_role(denied.id, viewer_role).await.unwrap();
    s.assign_role(regranted.id, viewer_role).await.unwrap();
    s.assign_role(admin.id, admin_role).await.unwrap();

    let channel = s.create_channel("general", "text").await.unwrap();
    // Role tier denies VIEW; one member gets it back individually.
    s.set_role_overwrite(channel.id, viewer_role, NONE, VIEW)
        .await
        .unwrap();
    s.set_member_overwrite(channel.id, regranted.id, VIEW, NONE)
        .await
        .unwrap();
    // The denied member also carries an unrelated allow, so the member
    // overwrite path is exercised without regranting VIEW.
    s.set_member_overwrite(channel.id, denied.id, SEND, NONE)
        .await
        .unwrap();

    let everyone = [plain.id, viewer.id, denied.id, regranted.id, admin.id];
    let batched = s.viewers_among(channel.id, &everyone).await.unwrap();
    for user_id in everyone {
        let single = s.has_permission(user_id, channel.id, VIEW).await.unwrap();
        assert_eq!(
            batched.contains(&user_id),
            single,
            "batched and per-user answers diverged for {user_id:?}"
        );
    }
    assert_eq!(batched, vec![regranted.id, admin.id]);

    // A DM: only the pair is visible, however many candidates are offered.
    let dm = s.open_dm(plain.id, viewer.id).await.unwrap();
    let dm_viewers = s.viewers_among(dm.id, &everyone).await.unwrap();
    assert_eq!(dm_viewers, vec![plain.id, viewer.id]);

    // A channel that does not exist grants nothing, same as the single check.
    let ghost = slimm_server::ids::ChannelId::generate();
    assert!(s.viewers_among(ghost, &everyone).await.unwrap().is_empty());
}

/// The batched channel listing must be indistinguishable from filtering
/// [`Store::list_channels`] with [`Store::has_permission`] per channel; the
/// rail is built from this on every client startup.
#[tokio::test]
async fn visible_channels_matches_the_per_channel_check() {
    let (s, _guard) = store().await;
    let everyone_id = s.create_role("everyone", VIEW, true).await.unwrap();
    let mod_role = s.create_role("mod", SEND, false).await.unwrap();

    let member = s.create_user("member", "Member").await.unwrap();
    let modded = s.create_user("modded", "Modded").await.unwrap();
    s.assign_role(modded.id, mod_role).await.unwrap();

    let open = s.create_channel("open", "text").await.unwrap();
    let staff = s.create_channel("staff", "text").await.unwrap();
    let restored = s.create_channel("restored", "text").await.unwrap();
    // staff: @everyone denied VIEW, mod role regrants it.
    s.set_role_overwrite(staff.id, everyone_id, NONE, VIEW)
        .await
        .unwrap();
    s.set_role_overwrite(staff.id, mod_role, VIEW, NONE)
        .await
        .unwrap();
    // restored: @everyone denied, one member individually regranted.
    s.set_role_overwrite(restored.id, everyone_id, NONE, VIEW)
        .await
        .unwrap();
    s.set_member_overwrite(restored.id, member.id, VIEW, NONE)
        .await
        .unwrap();

    for user in [member.id, modded.id] {
        let batched: Vec<_> = s
            .visible_channels(user)
            .await
            .unwrap()
            .into_iter()
            .map(|c| c.id)
            .collect();
        for channel in [open.id, staff.id, restored.id] {
            let single = s.has_permission(user, channel, VIEW).await.unwrap();
            assert_eq!(
                batched.contains(&channel),
                single,
                "batched and per-channel answers diverged for {user:?} in {channel:?}"
            );
        }
    }
}

/// `restricted` - whether `@everyone` itself lacks VIEW_CHANNEL - is a
/// property of the channel, not the caller: it must read the same for two
/// callers who see the channel through entirely different grants (a role
/// overwrite for `modded`, a member overwrite for `member`), and must be
/// false for a channel `@everyone` can see plainly. Both users hold the mod
/// role and both get their own member overwrite on `restored`, so every
/// channel is visible to both and `restricted` can be compared across them
/// on all three rather than only on the one each would see alone.
#[tokio::test]
async fn visible_channels_with_permissions_reports_restricted_independent_of_caller() {
    let (s, _guard) = store().await;
    let everyone_id = s.create_role("everyone", VIEW, true).await.unwrap();
    let mod_role = s.create_role("mod", SEND, false).await.unwrap();

    let member = s.create_user("member", "Member").await.unwrap();
    let modded = s.create_user("modded", "Modded").await.unwrap();
    s.assign_role(member.id, mod_role).await.unwrap();
    s.assign_role(modded.id, mod_role).await.unwrap();

    let open = s.create_channel("open", "text").await.unwrap();
    let staff = s.create_channel("staff", "text").await.unwrap();
    let restored = s.create_channel("restored", "text").await.unwrap();
    // staff: @everyone denied VIEW, mod role regrants it.
    s.set_role_overwrite(staff.id, everyone_id, NONE, VIEW)
        .await
        .unwrap();
    s.set_role_overwrite(staff.id, mod_role, VIEW, NONE)
        .await
        .unwrap();
    // restored: @everyone denied, each member individually regranted.
    s.set_role_overwrite(restored.id, everyone_id, NONE, VIEW)
        .await
        .unwrap();
    s.set_member_overwrite(restored.id, member.id, VIEW, NONE)
        .await
        .unwrap();
    s.set_member_overwrite(restored.id, modded.id, VIEW, NONE)
        .await
        .unwrap();

    for user in [member.id, modded.id] {
        let restricted_by_id: std::collections::HashMap<_, _> = s
            .visible_channels_with_permissions(user)
            .await
            .unwrap()
            .into_iter()
            .map(|(channel, _, restricted)| (channel.id, restricted))
            .collect();
        assert!(!restricted_by_id[&open.id], "an ordinary channel");
        assert!(
            restricted_by_id[&staff.id],
            "@everyone is denied VIEW here even though {user:?} sees it via a role"
        );
        assert!(
            restricted_by_id[&restored.id],
            "@everyone is denied VIEW here even though {user:?} sees it via a member overwrite"
        );
    }
}

/// The report queue's batched lookup must be indistinguishable, id by id,
/// from calling [`Store::permissions_in_channel`] once per id - including
/// the two cases `channels_where` structurally cannot reach, a DM and a
/// deleted channel, which are exactly what the report queue needs this
/// function for. See docs/decisions/0011-per-channel-permissions.md.
#[tokio::test]
async fn permissions_in_channels_matches_the_per_channel_check() {
    let (s, _guard) = store().await;
    let everyone_role = s
        .create_role("everyone", VIEW.union(SEND), true)
        .await
        .unwrap();
    let mods = s
        .create_role("mods", Permissions::MANAGE_MESSAGES, false)
        .await
        .unwrap();

    let alice = s.create_user("alice", "Alice").await.unwrap();
    let bob = s.create_user("bob", "Bob").await.unwrap();
    s.assign_role(alice.id, mods).await.unwrap();

    let ordinary = s.create_channel("general", "text").await.unwrap();
    let to_delete = s.create_channel("gone", "text").await.unwrap();
    s.delete_channel(to_delete.id).await.unwrap();
    // A real overwrite on the parent, so a thread that skipped resolving to it would answer differently.
    s.set_role_overwrite(ordinary.id, everyone_role, NONE, SEND)
        .await
        .unwrap();

    let parent_message = s
        .send_message(NewMessage::plain(
            ordinary.id,
            alice.id,
            slimm_server::ids::MessageId::generate(),
            "start a thread here",
        ))
        .await
        .unwrap()
        .message;
    let thread = s.open_thread(ordinary.id, parent_message.id).await.unwrap();

    let dm = s.open_dm(alice.id, bob.id).await.unwrap();

    let ids = vec![ordinary.id, to_delete.id, thread.channel.id, dm.id];
    let batched = s.permissions_in_channels(alice.id, &ids).await.unwrap();

    for &id in &ids {
        let single = s.permissions_in_channel(alice.id, id).await.unwrap();
        let masked = slimm_server::permissions::mask_unless_viewable(single);
        assert_eq!(
            batched.get(&id).copied().unwrap_or(NONE),
            masked,
            "batched and per-channel answers diverged for {id:?}"
        );
    }
    assert_eq!(
        batched[&to_delete.id], NONE,
        "a deleted channel must answer NONE, same as the per-channel check"
    );

    // A fabricated id, never asked about above, answers the same way.
    let ghost = slimm_server::ids::ChannelId::generate();
    let ghost_batch = s.permissions_in_channels(alice.id, &[ghost]).await.unwrap();
    assert_eq!(ghost_batch[&ghost], NONE);

    // A repeated id in one request is resolved once and answers once.
    let doubled = s
        .permissions_in_channels(alice.id, &[ordinary.id, ordinary.id])
        .await
        .unwrap();
    assert_eq!(doubled.len(), 1);
}

/// The batch function's own existence-probe mask must actually fire, not
/// merely happen to agree with an unmasked answer that was already zero: a
/// channel that denies VIEW_CHANNEL to everyone still leaves this member's
/// MANAGE_MESSAGES role grant untouched right up until the mask is applied.
#[tokio::test]
async fn permissions_in_channels_masks_a_channel_the_caller_cannot_view() {
    let (s, _guard) = store().await;
    let everyone = s.create_role("everyone", NONE, true).await.unwrap();
    let mods = s
        .create_role("mods", Permissions::MANAGE_MESSAGES, false)
        .await
        .unwrap();
    let carol = s.create_user("carol", "Carol").await.unwrap();
    s.assign_role(carol.id, mods).await.unwrap();

    let hidden = s.create_channel("hidden", "text").await.unwrap();
    s.set_role_overwrite(hidden.id, everyone, NONE, VIEW)
        .await
        .unwrap();

    let unmasked = s
        .granted_permissions_in_channel(carol.id, hidden.id)
        .await
        .unwrap();
    assert!(
        unmasked.contains(Permissions::MANAGE_MESSAGES),
        "the role grant must still be there before masking, or this test proves nothing"
    );

    let batched = s
        .permissions_in_channels(carol.id, &[hidden.id])
        .await
        .unwrap();
    assert_eq!(
        batched[&hidden.id], NONE,
        "lacking VIEW_CHANNEL must mask away every other bit too"
    );
}
