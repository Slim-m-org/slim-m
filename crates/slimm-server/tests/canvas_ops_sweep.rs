// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The canvas op compaction sweep: what it may delete, what it must never
//! delete, and the order the two passes have to run in.
//!
//! Driven against channels seeded with real prior activity - several
//! placements, overlapping remove/restore/clear pairs, some fully undone and
//! some not - rather than an empty database, the same discipline 0034's own
//! migration doc names after losing every `canvas_op_targets` row to a
//! cascade that a fresh-table test never exercised.

use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ids::{CanvasObjectId, CanvasOpId, ChannelId, UserId};
use slimm_server::store::{CanvasOpRequest, PlaceRequest, Store};
use sqlx::SqlitePool;

mod support;

use support::app::register_id as register;

const DAY_MS: i64 = 24 * 60 * 60 * 1000;
/// One more than `canvas_ops_sweep::CANVAS_OP_RETENTION_MS`'s own 30 days, so
/// "aged" unambiguously crosses the cutoff rather than landing on it.
const AGE_DAYS: i64 = 31;

async fn harness() -> (Store, SqlitePool, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new("slimm-canvas-ops-sweep");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool.clone()), pool, guard)
}

async fn general(store: &Store) -> ChannelId {
    store.list_channels().await.unwrap()[0].id
}

async fn place(store: &Store, channel: ChannelId, author: UserId) -> CanvasObjectId {
    let id = CanvasObjectId::generate();
    store
        .place_canvas_object(
            channel,
            author,
            id,
            PlaceRequest {
                kind: "stroke",
                bounds: (0.0, 0.0, 1.0, 1.0),
                props: "{}",
                attachment: None,
            },
        )
        .await
        .expect("placed");
    id
}

async fn submit(
    store: &Store,
    channel: ChannelId,
    actor: UserId,
    request: CanvasOpRequest,
) -> CanvasOpId {
    let op_id = CanvasOpId::generate();
    store
        .submit_canvas_op(channel, actor, op_id, true, request)
        .await
        .expect("authorized");
    op_id
}

/// Backdates every `canvas_ops` row so age-based eligibility can be tested
/// without a real clock, the same technique `attachment_sweep.rs`'s own
/// `age_attachments` uses for `attachments.created_at`. Shifts
/// `canvas_objects.deleted_at` back by the identical amount, or a clear's
/// exact-timestamp guard (`deleted_at = created_at`) would desync the moment
/// only one side of that equality was aged.
async fn age_all_ops(pool: &SqlitePool, days: i64) {
    let delta = days * DAY_MS;
    sqlx::query("UPDATE canvas_ops SET created_at = created_at - ?")
        .bind(delta)
        .execute(pool)
        .await
        .expect("age ops");
    sqlx::query(
        "UPDATE canvas_objects SET deleted_at = deleted_at - ? WHERE deleted_at IS NOT NULL",
    )
    .bind(delta)
    .execute(pool)
    .await
    .expect("age deletions");
}

/// Backdates one specific op by id, for a scenario where two ops must age
/// out on different sweeps. Does not touch `canvas_objects.deleted_at`; a
/// caller aging a `remove` or a `clear` specifically also needs
/// `age_deleted_at`, or the exact-timestamp fence both kinds are restored
/// and swept through desyncs the same way `age_all_ops`'s own doc explains.
async fn age_op(pool: &SqlitePool, id: CanvasOpId, days: i64) {
    sqlx::query("UPDATE canvas_ops SET created_at = created_at - ? WHERE id = ?")
        .bind(days * DAY_MS)
        .bind(id)
        .execute(pool)
        .await
        .expect("age one op");
}

/// Backdates every currently-dead object's `deleted_at`, the half of aging a
/// `clear` op that `age_op` alone cannot do since it only knows an op id.
async fn age_deleted_at(pool: &SqlitePool, days: i64) {
    sqlx::query(
        "UPDATE canvas_objects SET deleted_at = deleted_at - ? WHERE deleted_at IS NOT NULL",
    )
    .bind(days * DAY_MS)
    .execute(pool)
    .await
    .expect("age deletions");
}

async fn op_survives(pool: &SqlitePool, id: CanvasOpId) -> bool {
    sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM canvas_ops WHERE id = ?")
        .bind(id)
        .fetch_one(pool)
        .await
        .unwrap()
        > 0
}

async fn target_rows_for(pool: &SqlitePool, channel: ChannelId, op: CanvasOpId) -> i64 {
    sqlx::query_scalar::<_, i64>(
        "SELECT COUNT(*) FROM canvas_op_targets t
         JOIN canvas_ops o ON o.channel_id = t.channel_id AND o.seq = t.seq
         WHERE o.id = ? AND t.channel_id = ?",
    )
    .bind(op)
    .bind(channel)
    .fetch_one(pool)
    .await
    .unwrap()
}

async fn audit_actions_for(pool: &SqlitePool, object: CanvasObjectId) -> Vec<String> {
    sqlx::query_scalar::<_, String>(
        "SELECT action FROM canvas_audit_log WHERE object_id = ? ORDER BY id",
    )
    .bind(object)
    .fetch_all(pool)
    .await
    .unwrap()
}

async fn is_alive(pool: &SqlitePool, object: CanvasObjectId) -> bool {
    sqlx::query_scalar::<_, Option<i64>>("SELECT deleted_at FROM canvas_objects WHERE id = ?")
        .bind(object)
        .fetch_one(pool)
        .await
        .unwrap()
        .is_none()
}

/// A fully undone remove/restore pair, once old enough, is reclaimed
/// entirely: both op rows, and the target row the cascade should have taken
/// with them.
#[tokio::test]
async fn a_fully_undone_remove_and_its_restore_are_swept_once_old_enough() {
    let (store, pool, _guard) = harness().await;
    let actor = register(&store, "root").await;
    let channel = general(&store).await;
    let object = place(&store, channel, actor).await;

    let remove_op = submit(
        &store,
        channel,
        actor,
        CanvasOpRequest::Remove(vec![object]),
    )
    .await;
    let restore_op = submit(
        &store,
        channel,
        actor,
        CanvasOpRequest::Restore {
            target_op: remove_op,
        },
    )
    .await;
    assert!(is_alive(&pool, object).await, "restored before the sweep");

    age_all_ops(&pool, AGE_DAYS).await;
    let swept = store.sweep_canvas_ops().await.unwrap();

    assert_eq!(swept.removes, 1);
    assert_eq!(swept.restores, 1);
    assert!(!op_survives(&pool, remove_op).await, "the remove is gone");
    assert!(!op_survives(&pool, restore_op).await, "the restore is gone");
    assert_eq!(
        target_rows_for(&pool, channel, remove_op).await,
        0,
        "canvas_op_targets cascaded with its remove"
    );
    assert!(is_alive(&pool, object).await, "the object is still alive");

    // The audit trail outlives both swept op rows.
    assert_eq!(
        audit_actions_for(&pool, object).await,
        vec!["remove".to_owned(), "restore".to_owned()]
    );
}

/// A remove that killed something still dead must never be swept, however
/// old it is - deleting it would make that death permanently un-undoable.
#[tokio::test]
async fn a_remove_with_a_still_dead_target_is_never_swept() {
    let (store, pool, _guard) = harness().await;
    let actor = register(&store, "root").await;
    let channel = general(&store).await;
    let object = place(&store, channel, actor).await;
    let remove_op = submit(
        &store,
        channel,
        actor,
        CanvasOpRequest::Remove(vec![object]),
    )
    .await;

    age_all_ops(&pool, AGE_DAYS).await;
    let swept = store.sweep_canvas_ops().await.unwrap();

    assert_eq!(swept.total(), 0);
    assert!(op_survives(&pool, remove_op).await);
    assert!(!is_alive(&pool, object).await, "still dead, as it must be");
}

/// The narrower half of the rule above: an object being *currently* dead is
/// not the same as being dead *because of this specific remove*. Once a
/// later, independent removal supersedes an old one - restored, then
/// re-removed by someone else entirely - the old remove can no longer
/// restore anything (`apply_restore`'s own exact-timestamp fence refuses
/// it), so retaining it any longer buys nothing. This is the sweep-side
/// half of the same authorization fix `restore_permission.rs`'s
/// `restoring_a_stale_remove_does_not_reach_past_a_later_independent_removal`
/// covers on the write side.
#[tokio::test]
async fn a_remove_superseded_by_a_later_independent_removal_is_swept() {
    let (store, pool, _guard) = harness().await;
    let actor = register(&store, "root").await;
    let channel = general(&store).await;
    let object = place(&store, channel, actor).await;

    let remove_a = submit(
        &store,
        channel,
        actor,
        CanvasOpRequest::Remove(vec![object]),
    )
    .await;
    let restore_a = submit(
        &store,
        channel,
        actor,
        CanvasOpRequest::Restore {
            target_op: remove_a,
        },
    )
    .await;
    assert!(
        is_alive(&pool, object).await,
        "restored before the re-remove"
    );

    let remove_b = submit(
        &store,
        channel,
        actor,
        CanvasOpRequest::Remove(vec![object]),
    )
    .await;
    assert!(
        !is_alive(&pool, object).await,
        "dead again, now because of B"
    );

    age_all_ops(&pool, AGE_DAYS).await;
    let swept = store.sweep_canvas_ops().await.unwrap();

    assert!(
        !op_survives(&pool, remove_a).await,
        "A can no longer restore anything and must be reclaimed"
    );
    assert!(
        !op_survives(&pool, restore_a).await,
        "A's own restore is equally spent"
    );
    assert!(
        op_survives(&pool, remove_b).await,
        "B is the one guarding the object's current, still-dead state"
    );
    assert_eq!(swept.removes, 1, "only A, not B");
    assert_eq!(swept.restores, 1);
    assert!(
        !is_alive(&pool, object).await,
        "B's deletion must survive the sweep"
    );
}

/// A restore blocks its own target's deletion regardless of the target's
/// age, until the restore itself ages out too - the FK direction the module
/// doc names: `target_op` points from the restore at the remove, so the
/// restore has to go first.
#[tokio::test]
async fn a_restore_protects_its_target_until_the_restore_itself_ages_out() {
    let (store, pool, _guard) = harness().await;
    let actor = register(&store, "root").await;
    let channel = general(&store).await;
    let object = place(&store, channel, actor).await;

    let remove_op = submit(
        &store,
        channel,
        actor,
        CanvasOpRequest::Remove(vec![object]),
    )
    .await;
    age_op(&pool, remove_op, AGE_DAYS).await;
    age_deleted_at(&pool, AGE_DAYS).await;

    // The restore is fresh: submitted after the remove was already aged out.
    let restore_op = submit(
        &store,
        channel,
        actor,
        CanvasOpRequest::Restore {
            target_op: remove_op,
        },
    )
    .await;

    let first_pass = store.sweep_canvas_ops().await.unwrap();
    assert_eq!(
        first_pass.total(),
        0,
        "the remove is old but a fresh restore still names it"
    );
    assert!(op_survives(&pool, remove_op).await);
    assert!(op_survives(&pool, restore_op).await);

    age_op(&pool, restore_op, AGE_DAYS).await;
    let second_pass = store.sweep_canvas_ops().await.unwrap();
    assert_eq!(second_pass.restores, 1);
    assert_eq!(second_pass.removes, 1);
    assert!(!op_survives(&pool, remove_op).await);
    assert!(!op_survives(&pool, restore_op).await);
}

/// The account-deletion anonymization this table needs, the same treatment
/// `canvas_ops.actor_id` and `message_ops.actor_id` already get - checked
/// independently of the sweep, since a swept op's audit rows must be
/// anonymizable too.
#[tokio::test]
async fn canvas_audit_log_actor_is_anonymized_on_account_deletion() {
    let (store, pool, _guard) = harness().await;
    let actor = register(&store, "root").await;
    let channel = general(&store).await;
    let object = place(&store, channel, actor).await;
    submit(
        &store,
        channel,
        actor,
        CanvasOpRequest::Remove(vec![object]),
    )
    .await;

    store.delete_account(actor).await.unwrap();

    let remaining: Option<Vec<u8>> =
        sqlx::query_scalar("SELECT actor_id FROM canvas_audit_log WHERE object_id = ?")
            .bind(object)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(remaining, None, "the actor is nulled, the row is not");
}

// The replay scenario lives in canvas_ops_sweep_replay.rs, the clear pass's own coverage in canvas_ops_sweep_clear.rs.
