// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Removing somebody from the Space: access goes, everything they wrote
//! stays.
//!
//! The two halves that matter most are the ones easiest to get backwards. A
//! removal has to survive the removed member signing in again, or it is not a
//! removal at all - which is why it is a row rather than a session sweep. And
//! it must not touch authorship, or a removal quietly becomes the account
//! deletion it is deliberately not.

use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::permissions::Permissions;
use slimm_server::store::{InviteCheck, NewMessage, OpenError, RemoveMemberError, Store};

mod support;

async fn store() -> (Store, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new("slimm-removal-test");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool), guard)
}

async fn is_removed(s: &Store, user_id: slimm_server::ids::UserId) -> bool {
    let removals = s.list_removals().await.unwrap();
    removals.iter().any(|r| r.user_id == user_id)
}

const VIEW: Permissions = Permissions::VIEW_CHANNEL;
const SEND: Permissions = Permissions::SEND_MESSAGES;

/// An administrator plus an ordinary member, the shape every test here needs.
async fn deployment(s: &Store) -> (slimm_server::store::User, slimm_server::store::User) {
    s.create_role("everyone", VIEW.union(SEND), true)
        .await
        .unwrap();
    let admin_role = s
        .create_role("admin", Permissions::ADMINISTRATOR, false)
        .await
        .unwrap();
    let admin = s.create_user("root", "Root").await.unwrap();
    s.assign_role(admin.id, admin_role).await.unwrap();
    let member = s.create_user("nia", "Nia").await.unwrap();
    (admin, member)
}

/// The one thing a removal has to do that a session revocation does not:
/// outlast the next sign-in attempt.
#[tokio::test]
async fn a_removed_member_cannot_open_a_new_session() {
    let (s, _guard) = store().await;
    let (admin, member) = deployment(&s).await;

    s.open_session(member.id, "phone")
        .await
        .expect("signing in works before the removal");

    s.remove_from_space(member.id, admin.id, Some("spam"))
        .await
        .unwrap();

    assert!(matches!(
        s.open_session(member.id, "phone").await,
        Err(OpenError::Removed)
    ));
}

/// Told apart from a deleted account on purpose: one is "this account no
/// longer exists" and the other is "you were removed", and offering the first
/// for the second sends somebody to create a duplicate account to fix it.
#[tokio::test]
async fn removal_and_deletion_are_different_refusals() {
    let (s, _guard) = store().await;
    let (admin, member) = deployment(&s).await;
    let leaver = s.create_user("omar", "Omar").await.unwrap();

    s.remove_from_space(member.id, admin.id, None)
        .await
        .unwrap();
    s.delete_account(leaver.id).await.unwrap();

    assert!(matches!(
        s.open_session(member.id, "phone").await,
        Err(OpenError::Removed)
    ));
    assert!(matches!(
        s.open_session(leaver.id, "phone").await,
        Err(OpenError::AccountGone)
    ));
}

/// Live access goes at once rather than lapsing whenever the access token
/// happened to expire.
#[tokio::test]
async fn removal_revokes_every_live_session() {
    let (s, _guard) = store().await;
    let (admin, member) = deployment(&s).await;

    let phone = s.open_session(member.id, "phone").await.unwrap();
    let laptop = s.open_session(member.id, "laptop").await.unwrap();

    let revoked = s
        .remove_from_space(member.id, admin.id, None)
        .await
        .unwrap();
    assert_eq!(revoked.len(), 2, "both sessions are returned to be closed");

    for token in [&phone.access_token, &laptop.access_token] {
        assert!(
            s.authenticate(token).await.unwrap().is_none(),
            "a removed member's live token must stop working"
        );
    }
}

/// Removing somebody is not a reason to rewrite a conversation other people
/// were part of. This is the line between a removal and an account deletion,
/// and the tempting shortcut - adding a removal check beside every
/// `deleted_at IS NULL` - is exactly what would erase it.
#[tokio::test]
async fn their_messages_stay_and_stay_attributed() {
    let (s, _guard) = store().await;
    let (admin, member) = deployment(&s).await;
    let channel = s.create_channel("general", "text").await.unwrap();

    s.send_message(NewMessage::plain(
        channel.id,
        member.id,
        slimm_server::ids::MessageId::generate(),
        "said before being removed",
    ))
    .await
    .unwrap();

    s.remove_from_space(member.id, admin.id, None)
        .await
        .unwrap();

    let listed = s.list_messages(channel.id, None, 50).await.unwrap();
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].content, "said before being removed");
    assert_eq!(
        listed[0].author_id,
        Some(member.id),
        "authorship survives a removal; anonymizing is what deletion does"
    );
}

/// The member list is the one place a removal has to show, and the removals
/// listing is the only place they are still nameable afterwards.
#[tokio::test]
async fn they_leave_the_member_list_and_appear_in_the_removals_list() {
    let (s, _guard) = store().await;
    let (admin, member) = deployment(&s).await;

    let before = s.list_members(None, 50).await.unwrap();
    assert!(before.iter().any(|u| u.id == member.id));

    s.remove_from_space(member.id, admin.id, Some("spam"))
        .await
        .unwrap();

    let after = s.list_members(None, 50).await.unwrap();
    assert!(!after.iter().any(|u| u.id == member.id));
    assert!(after.iter().any(|u| u.id == admin.id));

    let removals = s.list_removals().await.unwrap();
    assert_eq!(removals.len(), 1);
    assert_eq!(removals[0].user_id, member.id);
    assert_eq!(removals[0].username, "nia");
    assert_eq!(removals[0].reason.as_deref(), Some("spam"));
    assert_eq!(removals[0].removed_by, Some(admin.id));
}

/// `member_count` is what an invite shows a prospective joiner, and its own
/// doc comment claims a removed member does not count any more than they
/// appear in `list_members`. It filtered only `deleted_at`, so that claim was
/// false the moment removal shipped: the count stayed one too high for as
/// long as the removed member's account existed.
#[tokio::test]
async fn a_removed_member_does_not_count_toward_member_count() {
    let (s, _guard) = store().await;
    let (admin, member) = deployment(&s).await;

    assert_eq!(s.member_count().await.unwrap(), 2);

    s.remove_from_space(member.id, admin.id, Some("spam"))
        .await
        .unwrap();

    assert_eq!(
        s.member_count().await.unwrap(),
        1,
        "member_count must agree with list_members about a removed member"
    );
}

/// Otherwise a removal hands the way back in to whoever they gave a code to
/// on the way out.
#[tokio::test]
async fn their_unspent_invites_are_revoked() {
    let (s, _guard) = store().await;
    let (admin, member) = deployment(&s).await;

    let invite = s.create_invite(member.id, None, None, None).await.unwrap();
    assert!(matches!(
        s.check_invite(&invite.code).await.unwrap(),
        InviteCheck::Usable(_)
    ));

    s.remove_from_space(member.id, admin.id, None)
        .await
        .unwrap();

    assert!(
        matches!(
            s.check_invite(&invite.code).await.unwrap(),
            InviteCheck::Unusable
        ),
        "a removed member's outstanding invite must stop working"
    );
}

/// The same refusal account deletion carries, for the same reason: roles,
/// invites and moderation all need a bit no reachable account would hold.
///
/// The failure this pins is subtler than it looks. `administrator_count`
/// filtered only on `deleted_at`, so without teaching it about removals a
/// deployment could be left with zero usable administrators and no recovery
/// path, silently, with every pre-existing test still green.
#[tokio::test]
async fn the_last_administrator_cannot_be_removed() {
    let (s, _guard) = store().await;
    let (admin, member) = deployment(&s).await;

    assert!(matches!(
        s.remove_from_space(admin.id, admin.id, None).await,
        Err(RemoveMemberError::LastAdministrator)
    ));
    assert!(
        s.open_session(admin.id, "phone").await.is_ok(),
        "the refused removal must not have half-applied"
    );

    // With a second administrator in place the first becomes removable.
    let admin_role = s
        .create_role("admin2", Permissions::ADMINISTRATOR, false)
        .await
        .unwrap();
    s.assign_role(member.id, admin_role).await.unwrap();
    s.remove_from_space(admin.id, member.id, None)
        .await
        .unwrap();
}

/// Reversible, because a moderator acting in anger at 2am is the normal case.
#[tokio::test]
async fn a_removal_can_be_undone() {
    let (s, _guard) = store().await;
    let (admin, member) = deployment(&s).await;

    s.remove_from_space(member.id, admin.id, None)
        .await
        .unwrap();
    assert!(is_removed(&s, member.id).await);

    assert!(s.restore_to_space(member.id, admin.id).await.unwrap());
    assert!(!is_removed(&s, member.id).await);
    assert!(s.open_session(member.id, "phone").await.is_ok());
    assert!(s.list_removals().await.unwrap().is_empty());

    // Restoring somebody who was never removed says so rather than pretending.
    assert!(!s.restore_to_space(member.id, admin.id).await.unwrap());
}

/// Re-removing is a replace, not a second row, and it re-revokes anything
/// that reappeared in between.
#[tokio::test]
async fn removing_twice_replaces_rather_than_stacking() {
    let (s, _guard) = store().await;
    let (admin, member) = deployment(&s).await;

    s.remove_from_space(member.id, admin.id, Some("first"))
        .await
        .unwrap();
    s.remove_from_space(member.id, admin.id, Some("second"))
        .await
        .unwrap();

    let removals = s.list_removals().await.unwrap();
    assert_eq!(removals.len(), 1);
    assert_eq!(removals[0].reason.as_deref(), Some("second"));
}

/// The whole point of MOD9: a removed member's registration invite has to
/// show up beside them in the removals list, so a moderator can recognize a
/// returning account by the code it came in through. Built on SRV5's
/// recording of `invite_redemptions`.
#[tokio::test]
async fn a_removed_members_registration_invite_shows_in_the_removals_list() {
    let (s, _guard) = store().await;
    let (admin, _member) = deployment(&s).await;

    let invite = s.create_invite(admin.id, None, None, None).await.unwrap();
    let joiner = s
        .register_account("evader", "Evader", "not-a-real-hash", Some(&invite.code))
        .await
        .unwrap();

    s.remove_from_space(joiner.id, admin.id, Some("ban evasion"))
        .await
        .unwrap();

    let removals = s.list_removals().await.unwrap();
    let entry = removals
        .iter()
        .find(|r| r.user_id == joiner.id)
        .expect("the removed joiner is in the removals list");
    assert_eq!(entry.invite_code.as_deref(), Some(invite.code.as_str()));
}

/// A member removed without ever having redeemed an invite reads as `None`,
/// not an error - open registration on an unclaimed deployment, or a
/// removed administrator who claimed it directly, both leave nothing to
/// report.
#[tokio::test]
async fn a_removed_member_with_no_invite_has_no_invite_code() {
    let (s, _guard) = store().await;
    let (admin, member) = deployment(&s).await;

    s.remove_from_space(member.id, admin.id, None)
        .await
        .unwrap();

    let removals = s.list_removals().await.unwrap();
    let entry = removals
        .iter()
        .find(|r| r.user_id == member.id)
        .expect("the removed member is in the removals list");
    assert!(entry.invite_code.is_none());
}

#[tokio::test]
async fn removing_an_account_that_does_not_exist_says_so() {
    let (s, _guard) = store().await;
    let (admin, _member) = deployment(&s).await;
    let ghost = slimm_server::ids::UserId::generate();

    assert!(matches!(
        s.remove_from_space(ghost, admin.id, None).await,
        Err(RemoveMemberError::UserNotFound)
    ));
}

/// A bot has no sign-in to retry. "Readmission restores the right to sign in"
/// is the correct call for a human, and vacuous for a principal that cannot
/// sign in at all: restoring it must leave the one credential it has working
/// again, or removal is a one-way trip for a bot.
#[tokio::test]
async fn restoring_a_removed_bot_revives_its_token() {
    let (s, _guard) = store().await;
    let (admin, _member) = deployment(&s).await;

    let new_bot = s
        .create_bot("modbot", "Modbot", Permissions::NONE, admin.id)
        .await
        .unwrap();
    let bot_id = new_bot.bot.user_id;
    let token = new_bot.token;
    assert!(s.authenticate_bot(&token).await.unwrap().is_some());

    s.remove_from_space(bot_id, admin.id, Some("investigating"))
        .await
        .unwrap();
    assert!(
        s.authenticate_bot(&token).await.unwrap().is_none(),
        "removal must still cut the bot off immediately"
    );

    assert!(s.restore_to_space(bot_id, admin.id).await.unwrap());

    assert!(
        s.authenticate_bot(&token).await.unwrap().is_some(),
        "a restored bot must be able to authenticate with its original token"
    );
}

/// The human path must stay exactly as it was: readmission lifts the refusal
/// to sign in, it does not raise the session that was live at removal time.
#[tokio::test]
async fn restoring_a_removed_human_does_not_revive_their_old_session() {
    let (s, _guard) = store().await;
    let (admin, member) = deployment(&s).await;

    let issued = s.open_session(member.id, "phone").await.unwrap();

    s.remove_from_space(member.id, admin.id, None)
        .await
        .unwrap();
    assert!(
        s.authenticate(&issued.access_token)
            .await
            .unwrap()
            .is_none()
    );

    assert!(s.restore_to_space(member.id, admin.id).await.unwrap());

    assert!(
        s.authenticate(&issued.access_token)
            .await
            .unwrap()
            .is_none(),
        "restoring a human must not revive the session token they held when removed"
    );
    assert!(
        s.open_session(member.id, "phone").await.is_ok(),
        "a restored human signs back in fresh instead"
    );
}

/// A bot whose token was independently revoked before its removal must stay
/// dead on restore. Readmission only reverses what the removal itself did; it
/// is not a second way to undo an explicit revocation.
#[tokio::test]
async fn restoring_a_bot_does_not_revive_a_token_already_revoked_before_removal() {
    let (s, _guard) = store().await;
    let (admin, _member) = deployment(&s).await;

    let new_bot = s
        .create_bot("watchbot", "Watchbot", Permissions::NONE, admin.id)
        .await
        .unwrap();
    let bot_id = new_bot.bot.user_id;
    let token = new_bot.token;

    s.revoke_bot(bot_id, admin.id).await.unwrap();
    s.remove_from_space(bot_id, admin.id, None).await.unwrap();
    assert!(s.restore_to_space(bot_id, admin.id).await.unwrap());

    assert!(
        s.authenticate_bot(&token).await.unwrap().is_none(),
        "an explicitly revoked bot token must not come back from a restore"
    );
}
