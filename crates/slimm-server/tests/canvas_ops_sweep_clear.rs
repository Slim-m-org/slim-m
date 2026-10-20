// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The compaction sweep's `clear` pass, split out of `canvas_ops_sweep.rs`
//! once that file crossed the 500-line hard limit.
//!
//! Fixtures are duplicated rather than shared, the same choice
//! `canvas_ops_sweep_replay.rs` already made for the identical reason:
//! integration test binaries in this crate do not link against each other.

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
    let (path, guard) = support::TestDbGuard::new("slimm-canvas-ops-sweep-clear");
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
/// without a real clock. Shifts `canvas_objects.deleted_at` back by the
/// identical amount, or a clear's exact-timestamp guard
/// (`deleted_at = created_at`) would desync the moment only one side of that
/// equality was aged.
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
/// caller aging a `clear` specifically also needs `age_deleted_at`, or the
/// exact-timestamp fence a clear is restored and swept through desyncs the
/// same way `age_all_ops`'s own doc explains.
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

async fn is_alive(pool: &SqlitePool, object: CanvasObjectId) -> bool {
    sqlx::query_scalar::<_, Option<i64>>("SELECT deleted_at FROM canvas_objects WHERE id = ?")
        .bind(object)
        .fetch_one(pool)
        .await
        .unwrap()
        .is_none()
}

/// The same protection the remove case gets, for a clear rather than a
/// remove: a distinct SQL gate in the sweep's own clear pass, so it earns
/// its own test rather than relying on the remove case to stand in for it.
#[tokio::test]
async fn a_restore_protects_its_clear_target_until_the_restore_itself_ages_out() {
    let (store, pool, _guard) = harness().await;
    let actor = register(&store, "root").await;
    let channel = general(&store).await;
    place(&store, channel, actor).await;
    let head = store
        .list_canvas_ops(channel, 0, 1)
        .await
        .unwrap()
        .latest_seq;
    let clear_op = submit(
        &store,
        channel,
        actor,
        CanvasOpRequest::Clear {
            before_seq: head,
            scope: Default::default(),
        },
    )
    .await;
    age_op(&pool, clear_op, AGE_DAYS).await;
    age_deleted_at(&pool, AGE_DAYS).await;

    let restore_op = submit(
        &store,
        channel,
        actor,
        CanvasOpRequest::Restore {
            target_op: clear_op,
        },
    )
    .await;

    let first_pass = store.sweep_canvas_ops().await.unwrap();
    assert_eq!(
        first_pass.total(),
        0,
        "the clear is old but a fresh restore still names it"
    );
    assert!(op_survives(&pool, clear_op).await);

    age_op(&pool, restore_op, AGE_DAYS).await;
    let second_pass = store.sweep_canvas_ops().await.unwrap();
    assert_eq!(second_pass.clears, 1);
    assert_eq!(second_pass.restores, 1);
    assert!(!op_survives(&pool, clear_op).await);
    assert!(!op_survives(&pool, restore_op).await);
}

/// A clear that still holds a dead object survives, symmetrically with the
/// remove case, checked against the exact-timestamp fence
/// `canvas_ops_apply::restore_candidates` uses for a clear rather than
/// `canvas_op_targets`, which a clear never writes.
#[tokio::test]
async fn a_clear_with_a_still_dead_target_is_never_swept() {
    let (store, pool, _guard) = harness().await;
    let actor = register(&store, "root").await;
    let channel = general(&store).await;
    let object = place(&store, channel, actor).await;
    let head = store
        .list_canvas_ops(channel, 0, 1)
        .await
        .unwrap()
        .latest_seq;
    let clear_op = submit(
        &store,
        channel,
        actor,
        CanvasOpRequest::Clear {
            before_seq: head,
            scope: Default::default(),
        },
    )
    .await;

    age_all_ops(&pool, AGE_DAYS).await;
    let swept = store.sweep_canvas_ops().await.unwrap();

    assert_eq!(swept.total(), 0);
    assert!(op_survives(&pool, clear_op).await);
    assert!(!is_alive(&pool, object).await);
}

/// The clear counterpart of the fully-undone remove case: once its object is
/// back, and both ops are old, both are reclaimed.
#[tokio::test]
async fn a_fully_undone_clear_and_its_restore_are_swept_once_old_enough() {
    let (store, pool, _guard) = harness().await;
    let actor = register(&store, "root").await;
    let channel = general(&store).await;
    let object = place(&store, channel, actor).await;
    let head = store
        .list_canvas_ops(channel, 0, 1)
        .await
        .unwrap()
        .latest_seq;
    let clear_op = submit(
        &store,
        channel,
        actor,
        CanvasOpRequest::Clear {
            before_seq: head,
            scope: Default::default(),
        },
    )
    .await;
    let restore_op = submit(
        &store,
        channel,
        actor,
        CanvasOpRequest::Restore {
            target_op: clear_op,
        },
    )
    .await;

    age_all_ops(&pool, AGE_DAYS).await;
    let swept = store.sweep_canvas_ops().await.unwrap();

    assert_eq!(swept.clears, 1);
    assert_eq!(swept.restores, 1);
    assert!(!op_survives(&pool, clear_op).await);
    assert!(!op_survives(&pool, restore_op).await);
    assert!(is_alive(&pool, object).await);
}
