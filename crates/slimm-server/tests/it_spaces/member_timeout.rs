// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A timeout takes away every way of expressing yourself and takes away
//! nothing else, everywhere permissions are read.
//!
//! The point of most of these is not that one route refuses. It is that the
//! subtraction happens in the one place all three read paths share, so a
//! route nobody thought about while writing this inherits it: the per-channel
//! path, the direct-message path that returns before the evaluator, and the
//! two batched paths that run their own copy of it.

use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;

use crate::support;
async fn store() -> (Store, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new("slimm-timeout-test");
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

/// Everything an ordinary member gets, which is also everything a timeout has
/// anything to say about.
const MEMBER: Permissions = VIEW
    .union(SEND)
    .union(Permissions::ADD_REACTIONS)
    .union(Permissions::ATTACH_FILES)
    .union(Permissions::CONNECT)
    .union(Permissions::SPEAK)
    .union(Permissions::USE_CANVAS);

const HOUR_MS: i64 = 60 * 60 * 1000;

fn now() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
}

/// The whole contract in one assertion: reading survives, expressing does not.
#[tokio::test]
async fn a_timeout_removes_expression_and_leaves_reading() {
    let (s, _guard) = store().await;
    s.create_role("everyone", MEMBER, true).await.unwrap();
    let user = s.create_user("nia", "Nia").await.unwrap();
    let channel = s.create_channel("general", "text").await.unwrap();

    let before = s.permissions_in_channel(user.id, channel.id).await.unwrap();
    assert!(before.contains(SEND));

    s.set_member_timeout(user.id, now() + HOUR_MS, Some("cool off"), user.id)
        .await
        .unwrap();
    let after = s.permissions_in_channel(user.id, channel.id).await.unwrap();

    assert!(
        after.contains(VIEW),
        "a timeout must never stop them reading"
    );
    for gone in [
        SEND,
        Permissions::ADD_REACTIONS,
        Permissions::ATTACH_FILES,
        Permissions::CONNECT,
        Permissions::SPEAK,
    ] {
        assert!(!after.intersects(gone), "{gone:?} should be gone");
    }
    // Not USE_CANVAS: it means view *and* draw, so losing it blanks the canvas.
    assert!(after.contains(Permissions::USE_CANVAS));
}

/// The deployment-wide read has to agree with the per-channel one, or a
/// timed-out member keeps whatever is gated on the former - which as of this
/// change includes uploading an attachment.
#[tokio::test]
async fn the_deployment_wide_read_is_masked_too() {
    let (s, _guard) = store().await;
    s.create_role("everyone", MEMBER, true).await.unwrap();
    let user = s.create_user("omar", "Omar").await.unwrap();

    s.set_member_timeout(user.id, now() + HOUR_MS, None, user.id)
        .await
        .unwrap();

    let base = s.base_permissions(user.id).await.unwrap();
    assert!(!base.intersects(Permissions::ATTACH_FILES));
    assert!(base.contains(VIEW));

    // Must not move: else a timeout is what makes somebody re-timeout-able.
    let granted = s.granted_base_permissions(user.id).await.unwrap();
    assert!(granted.contains(Permissions::ATTACH_FILES));
}

/// A direct message returns from `permissions_in_channel` before the
/// evaluator ever runs, so a mask written beside the evaluator would spare
/// DMs entirely - the one channel kind where nobody else is present to
/// notice it did not apply.
#[tokio::test]
async fn a_timeout_reaches_direct_messages() {
    let (s, _guard) = store().await;
    s.create_role("everyone", MEMBER, true).await.unwrap();
    let nia = s.create_user("nia", "Nia").await.unwrap();
    let omar = s.create_user("omar", "Omar").await.unwrap();
    let dm = s.open_dm(nia.id, omar.id).await.unwrap();

    assert!(s.has_permission(nia.id, dm.id, SEND).await.unwrap());
    s.set_member_timeout(nia.id, now() + HOUR_MS, None, omar.id)
        .await
        .unwrap();

    assert!(!s.has_permission(nia.id, dm.id, SEND).await.unwrap());
    assert!(
        s.has_permission(nia.id, dm.id, VIEW).await.unwrap(),
        "the conversation is still readable"
    );
    // The other party is untouched: a timeout is about one person.
    assert!(s.has_permission(omar.id, dm.id, SEND).await.unwrap());
}

/// `viewers_among` and `visible_channels` run their own copy of the
/// evaluator, so they can drift from the per-user path silently. Both only
/// ask about VIEW_CHANNEL today, which a timeout deliberately does not touch,
/// so the outcome here is "nothing changes" - and that is exactly the point:
/// a timed-out member must keep receiving pushes and keep seeing their rail.
#[tokio::test]
async fn the_batched_paths_agree_with_the_per_user_path() {
    let (s, _guard) = store().await;
    s.create_role("everyone", MEMBER, true).await.unwrap();
    let quiet = s.create_user("quiet", "Quiet").await.unwrap();
    let loud = s.create_user("loud", "Loud").await.unwrap();
    let open = s.create_channel("general", "text").await.unwrap();
    let dm = s.open_dm(quiet.id, loud.id).await.unwrap();

    s.set_member_timeout(quiet.id, now() + HOUR_MS, None, loud.id)
        .await
        .unwrap();

    let both = [quiet.id, loud.id];
    for channel in [open.id, dm.id] {
        let batched = s.viewers_among(channel, &both).await.unwrap();
        for user_id in both {
            let single = s.has_permission(user_id, channel, VIEW).await.unwrap();
            assert_eq!(
                batched.contains(&user_id),
                single,
                "batched and per-user answers diverged for {user_id:?} in {channel:?}"
            );
        }
    }
    assert!(
        s.viewers_among(open.id, &both)
            .await
            .unwrap()
            .contains(&quiet.id),
        "a timed-out member still receives what happens in the channel"
    );

    let rail: Vec<_> = s
        .visible_channels(quiet.id)
        .await
        .unwrap()
        .into_iter()
        .map(|c| c.id)
        .collect();
    assert!(
        rail.contains(&open.id),
        "a timed-out member still sees the channel they cannot post in"
    );
}

/// Expiry is arithmetic against the clock, not a job that has to run. A row
/// whose deadline has passed is simply not a timeout any more.
#[tokio::test]
async fn an_elapsed_timeout_is_not_in_force() {
    let (s, _guard) = store().await;
    s.create_role("everyone", MEMBER, true).await.unwrap();
    let user = s.create_user("pia", "Pia").await.unwrap();
    let channel = s.create_channel("general", "text").await.unwrap();

    s.set_member_timeout(user.id, now() - 1, None, user.id)
        .await
        .unwrap();

    assert!(s.has_permission(user.id, channel.id, SEND).await.unwrap());
    assert_eq!(s.timed_out_until(user.id).await.unwrap(), None);
    assert!(s.member_timeout(user.id).await.unwrap().is_none());
}

/// Re-issuing replaces rather than stacks, which is also the only way a
/// moderator can shorten one they overdid.
#[tokio::test]
async fn re_issuing_replaces_the_deadline_in_both_directions() {
    let (s, _guard) = store().await;
    let user = s.create_user("rae", "Rae").await.unwrap();
    let moderator = s.create_user("kit", "Kit").await.unwrap();
    let long = now() + 24 * HOUR_MS;
    let short = now() + HOUR_MS;

    s.set_member_timeout(user.id, long, None, moderator.id)
        .await
        .unwrap();
    s.set_member_timeout(user.id, short, Some("shortened"), moderator.id)
        .await
        .unwrap();

    let held = s.member_timeout(user.id).await.unwrap().unwrap();
    assert_eq!(held.until, short);
    assert_eq!(held.reason.as_deref(), Some("shortened"));

    s.clear_member_timeout(user.id, moderator.id).await.unwrap();
    assert_eq!(s.timed_out_until(user.id).await.unwrap(), None);
    // Lifting an absent one still succeeds: they can speak either way.
    s.clear_member_timeout(user.id, moderator.id).await.unwrap();
}

/// The batched lookup the member list and push fan-out use has to answer the
/// same thing the single one does, including about people it was not asked
/// about.
#[tokio::test]
async fn the_batched_timeout_lookup_matches_the_single_one() {
    let (s, _guard) = store().await;
    let timed = s.create_user("timed", "Timed").await.unwrap();
    let free = s.create_user("free", "Free").await.unwrap();
    let elapsed = s.create_user("elapsed", "Elapsed").await.unwrap();
    let until = now() + HOUR_MS;

    s.set_member_timeout(timed.id, until, None, free.id)
        .await
        .unwrap();
    s.set_member_timeout(elapsed.id, now() - 1, None, free.id)
        .await
        .unwrap();

    let ids = [timed.id, free.id, elapsed.id];
    let batched = s.timed_out_among_until(&ids).await.unwrap();
    for id in ids {
        assert_eq!(
            batched.get(&id).copied(),
            s.timed_out_until(id).await.unwrap(),
            "batched and single timeout reads diverged for {id:?}"
        );
    }
    assert_eq!(batched.get(&timed.id).copied(), Some(until));
    assert!(!batched.contains_key(&elapsed.id));
    assert!(s.timed_out_among_until(&[]).await.unwrap().is_empty());
}

/// An administrator is masked like anybody else. The evaluator's
/// ADMINISTRATOR bypass returns every bit before the subtraction runs, so the
/// question is only whether the subtraction comes after it - and it must,
/// or a timeout would be silently unenforceable against exactly the accounts
/// most worth being able to stop.
#[tokio::test]
async fn an_administrator_is_masked_like_anyone_else() {
    let (s, _guard) = store().await;
    s.create_role("everyone", VIEW, true).await.unwrap();
    let admin_role = s
        .create_role("admin", Permissions::ADMINISTRATOR, false)
        .await
        .unwrap();
    let admin = s.create_user("root", "Root").await.unwrap();
    s.assign_role(admin.id, admin_role).await.unwrap();
    let channel = s.create_channel("general", "text").await.unwrap();

    s.set_member_timeout(admin.id, now() + HOUR_MS, None, admin.id)
        .await
        .unwrap();
    let perms = s
        .permissions_in_channel(admin.id, channel.id)
        .await
        .unwrap();

    assert!(!perms.intersects(SEND));
    // Only expression bits go, so they can still lift their own timeout.
    assert!(perms.contains(Permissions::ADMINISTRATOR));
    assert!(perms.contains(Permissions::MANAGE_MESSAGES));
}

/// A nonexistent channel still grants nothing, and the mask must not turn
/// that into a different answer by accident.
#[tokio::test]
async fn a_timeout_changes_nothing_about_a_channel_that_does_not_exist() {
    let (s, _guard) = store().await;
    s.create_role("everyone", MEMBER, true).await.unwrap();
    let user = s.create_user("nia", "Nia").await.unwrap();
    s.set_member_timeout(user.id, now() + HOUR_MS, None, user.id)
        .await
        .unwrap();

    let ghost = slimm_server::ids::ChannelId::generate();
    assert_eq!(
        s.permissions_in_channel(user.id, ghost).await.unwrap(),
        NONE
    );
}
