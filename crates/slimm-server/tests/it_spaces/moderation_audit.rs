// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Moderation keeps a record of what was done even after it is undone.
//!
//! `space_removals` and `member_timeouts` hold one row per member and answer
//! only "is this in force now", so lifting either deletes the only evidence
//! that it ever happened - who acted, on whom, and why. `moderation_audit_log`
//! is where the acts accumulate instead.
//!
//! Every case here uses two distinct moderators, one to impose and a different
//! one to lift. An audit trail that records the wrong actor is worse than none,
//! and a fixture where the same person does both cannot tell the two apart.
//!
//! The last two cases assert things that already hold today. They are here
//! because they are the two reads that would break if this table were ever
//! replaced by the `lifted_at` column the debt entry originally proposed: the
//! login gate and the last-administrator guard. Both fail closed in ways that
//! are very hard to undo on a self-hosted deployment - one locks every
//! reinstated member out permanently, the other can leave a Space with no
//! reachable administrator at all.

use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ids::UserId;
use slimm_server::permissions::Permissions;
use slimm_server::store::{OpenError, RemoveMemberError, Store, User};
use sqlx::SqlitePool;

use crate::support;
async fn harness() -> (Store, SqlitePool, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new("slimm-moderation-audit");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool.clone()), pool, guard)
}

const VIEW: Permissions = Permissions::VIEW_CHANNEL;
const SEND: Permissions = Permissions::SEND_MESSAGES;

/// Two moderators and a member. The two moderators are the point: every
/// assertion below distinguishes the one who acted from the one who undid it.
async fn people(s: &Store) -> (User, User, User) {
    s.create_role("everyone", VIEW.union(SEND), true)
        .await
        .unwrap();
    let admin_role = s
        .create_role("admin", Permissions::ADMINISTRATOR, false)
        .await
        .unwrap();
    let mod_a = s.create_user("ada", "Ada").await.unwrap();
    let mod_b = s.create_user("bram", "Bram").await.unwrap();
    s.assign_role(mod_a.id, admin_role).await.unwrap();
    s.assign_role(mod_b.id, admin_role).await.unwrap();
    let member = s.create_user("nia", "Nia").await.unwrap();
    (mod_a, mod_b, member)
}

/// One member's trail, oldest first, as `(action, actor, reason, until)`.
async fn trail(
    pool: &SqlitePool,
    subject: UserId,
) -> Vec<(String, Option<Vec<u8>>, Option<String>, Option<i64>)> {
    sqlx::query_as(
        "SELECT action, actor_id, reason, until FROM moderation_audit_log
         WHERE subject_id = ? ORDER BY id",
    )
    .bind(subject)
    .fetch_all(pool)
    .await
    .expect("read the moderation audit log")
}

fn actor(id: UserId) -> Option<Vec<u8>> {
    Some(id.0.as_bytes().to_vec())
}

#[tokio::test]
async fn a_lifted_removal_still_names_the_moderator_who_made_it() {
    let (store, pool, _guard) = harness().await;
    let (mod_a, mod_b, nia) = people(&store).await;

    store
        .remove_from_space(nia.id, mod_a.id, Some("spam"))
        .await
        .unwrap();
    assert!(store.restore_to_space(nia.id, mod_b.id).await.unwrap());

    assert!(
        store.list_removals().await.unwrap().is_empty(),
        "the live table still answers only what is in force"
    );
    assert_eq!(
        trail(&pool, nia.id).await,
        vec![
            (
                "remove".to_owned(),
                actor(mod_a.id),
                Some("spam".to_owned()),
                None
            ),
            ("restore".to_owned(), actor(mod_b.id), None, None),
        ],
        "the removal and who undid it both survive the undo"
    );
}

#[tokio::test]
async fn a_cleared_timeout_still_names_the_moderator_and_the_deadline() {
    let (store, pool, _guard) = harness().await;
    let (mod_a, mod_b, nia) = people(&store).await;
    let until = 4_102_444_800_000;

    store
        .set_member_timeout(nia.id, until, Some("cool off"), mod_a.id)
        .await
        .unwrap();
    store.clear_member_timeout(nia.id, mod_b.id).await.unwrap();

    assert!(
        store.member_timeout(nia.id).await.unwrap().is_none(),
        "the timeout really is lifted"
    );
    assert_eq!(
        trail(&pool, nia.id).await,
        vec![
            (
                "timeout".to_owned(),
                actor(mod_a.id),
                Some("cool off".to_owned()),
                Some(until)
            ),
            (
                "timeout_cleared".to_owned(),
                actor(mod_b.id),
                None,
                Some(until)
            ),
        ],
        "a lift records who lifted it and which deadline it cut short"
    );
}

/// Both undo paths are documented as idempotent, so both get called on
/// somebody who was never moderated at all. Recording those would put acts in
/// the trail that never happened.
#[tokio::test]
async fn an_undo_that_undid_nothing_records_nothing() {
    let (store, pool, _guard) = harness().await;
    let (mod_a, _mod_b, nia) = people(&store).await;

    store.clear_member_timeout(nia.id, mod_a.id).await.unwrap();
    assert!(
        !store.restore_to_space(nia.id, mod_a.id).await.unwrap(),
        "restoring somebody who was not removed still reports it did nothing"
    );

    assert!(
        trail(&pool, nia.id).await.is_empty(),
        "an undo that changed nothing is not an act"
    );
}

/// A refusal must leave nothing behind, in the live table or the trail.
///
/// `remove_from_space` writes the removal row first and only then counts the
/// administrators left, so the refusal is a rollback rather than a check. What
/// this pins is that the rollback still comes before anything is committed:
/// moving the count to after `tx.commit()` - the obvious "tidy up the ordering"
/// edit - leaves both a removal and an audit row behind for a removal that
/// reports as refused, and fails here.
///
/// The second assertion is not implied by the first. A refusal that rolls the
/// removal back correctly, and then records the attempt anyway on a connection
/// taken after the transaction is dropped, leaves `list_removals` empty and a
/// phantom act in the trail. That is the shape this line catches, and it is
/// why the trail is checked separately rather than trusted to follow from the
/// live table being clean.
#[tokio::test]
async fn a_refused_removal_leaves_no_audit_row() {
    let (store, pool, _guard) = harness().await;
    store
        .create_role("everyone", VIEW.union(SEND), true)
        .await
        .unwrap();
    let admin_role = store
        .create_role("admin", Permissions::ADMINISTRATOR, false)
        .await
        .unwrap();
    let only_admin = store.create_user("ada", "Ada").await.unwrap();
    store.assign_role(only_admin.id, admin_role).await.unwrap();

    let refused = store
        .remove_from_space(only_admin.id, only_admin.id, Some("mistake"))
        .await;
    assert!(matches!(refused, Err(RemoveMemberError::LastAdministrator)));

    assert!(
        store.list_removals().await.unwrap().is_empty(),
        "the refusal really did leave the live table alone"
    );
    assert!(
        trail(&pool, only_admin.id).await.is_empty(),
        "a removal that was refused is not a removal that happened"
    );
}

/// Re-issuing replaces the live row, which migration 0020 chose deliberately.
/// The log is where the replaced one survives, so the third timeout this month
/// is visible as the third rather than as the only one.
#[tokio::test]
async fn re_issuing_a_timeout_appends_rather_than_replacing() {
    let (store, pool, _guard) = harness().await;
    let (mod_a, mod_b, nia) = people(&store).await;
    let first = 4_102_444_800_000;
    let second = 4_102_444_900_000;

    store
        .set_member_timeout(nia.id, first, Some("one"), mod_a.id)
        .await
        .unwrap();
    store
        .set_member_timeout(nia.id, second, Some("two"), mod_b.id)
        .await
        .unwrap();

    let live = store.member_timeout(nia.id).await.unwrap().unwrap();
    assert_eq!(
        live.until, second,
        "the live row is still one row, replaced"
    );

    let entries = trail(&pool, nia.id).await;
    assert_eq!(entries.len(), 2, "but both issues are on the record");
    assert_eq!(entries[0].1, actor(mod_a.id));
    assert_eq!(entries[0].3, Some(first));
    assert_eq!(entries[1].1, actor(mod_b.id));
    assert_eq!(entries[1].3, Some(second));
}

/// Already true, and pinned so it stays true. `open_session` gates on the
/// absence of a `space_removals` row, so anything that leaves a lifted removal
/// behind locks every reinstated member out for good.
#[tokio::test]
async fn a_restored_member_can_open_a_session_again() {
    let (store, _pool, _guard) = harness().await;
    let (mod_a, mod_b, nia) = people(&store).await;

    store
        .remove_from_space(nia.id, mod_a.id, None)
        .await
        .unwrap();
    assert!(matches!(
        store.open_session(nia.id, "phone").await,
        Err(OpenError::Removed)
    ));

    assert!(store.restore_to_space(nia.id, mod_b.id).await.unwrap());
    store
        .open_session(nia.id, "phone")
        .await
        .expect("a restored member must be able to sign in again");
}

/// Already true, and pinned for the same reason. `administrator_count` skips
/// removed accounts, so a restored administrator has to count again - or a
/// Space can be walked down to zero reachable administrators one removal at a
/// time, which is the failure the last-administrator guard exists to prevent.
#[tokio::test]
async fn the_last_administrator_guard_counts_a_restored_member() {
    let (store, _pool, _guard) = harness().await;
    let (mod_a, mod_b, _nia) = people(&store).await;

    store
        .remove_from_space(mod_b.id, mod_a.id, None)
        .await
        .expect("two administrators, so removing one is allowed");
    assert!(store.restore_to_space(mod_b.id, mod_a.id).await.unwrap());

    store
        .remove_from_space(mod_a.id, mod_b.id, None)
        .await
        .expect("the restored administrator counts, so this is allowed");
    assert!(
        matches!(
            store.remove_from_space(mod_b.id, mod_b.id, None).await,
            Err(RemoveMemberError::LastAdministrator)
        ),
        "and now that they are the only one left, they are protected"
    );
}
