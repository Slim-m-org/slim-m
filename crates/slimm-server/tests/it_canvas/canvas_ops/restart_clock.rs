// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `Store::now_ms_unique`'s fence value must stay unique across a process
//! restart, not just within one running process.
//!
//! `restore_permission.rs` already proves the fence is exact *within* one
//! `Store`'s lifetime (`restoring_a_stale_remove_does_not_reach_past_a_later_
//! independent_removal`); this covers the boundary that fix's own doc comment
//! names as unclosed: an in-memory counter that resets to zero on restart can
//! hand out a value a still-live, un-restored fence already depends on being
//! unique to it alone.

use slimm_server::ids::CanvasOpId;
use slimm_server::store::{CanvasOpRequest, Store};

use crate::canvas_ops::fixtures::{general, new_store_and_pool, place, register};

/// A burst of concurrent submissions just before a crash can push
/// `now_ms_unique`'s in-memory counter several milliseconds ahead of the
/// wall clock; a plain in-memory counter forgets that the instant the process
/// restarts. This reproduces exactly that shape without needing an actual
/// crash: a `remove` op's `created_at` (the fence a later `restore` of it
/// would depend on) is pushed ten minutes into the future by hand, and a
/// brand new `Store` over the same database - what a real restart
/// constructs - must still answer its very first canvas op with a timestamp
/// strictly past that, not with plain `now_ms()`.
#[tokio::test]
async fn a_fresh_store_seeds_its_clock_past_a_pre_restart_high_water_mark() {
    let (store, pool, _guard) = new_store_and_pool().await;
    let (_token, actor) = register(&store, "root").await;
    let channel = general(&store).await;

    let object_a = place(&store, channel, actor, 0).await;
    let remove_op = CanvasOpId::generate();
    let outcome = store
        .submit_canvas_op(
            channel,
            actor,
            remove_op,
            true,
            CanvasOpRequest::Remove(vec![object_a]),
        )
        .await
        .expect("authorized");

    let future = outcome.created_at + 10 * 60 * 1000;
    sqlx::query("UPDATE canvas_ops SET created_at = ? WHERE id = ?")
        .bind(future)
        .bind(remove_op)
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query("UPDATE canvas_objects SET deleted_at = ? WHERE id = ?")
        .bind(future)
        .bind(object_a)
        .execute(&pool)
        .await
        .unwrap();

    // What a real process restart constructs: a fresh, unseeded `Store`.
    let restarted = Store::new(pool.clone());
    let object_b = place(&restarted, channel, actor, 0).await;
    let remove_op_2 = CanvasOpId::generate();
    let outcome_2 = restarted
        .submit_canvas_op(
            channel,
            actor,
            remove_op_2,
            true,
            CanvasOpRequest::Remove(vec![object_b]),
        )
        .await
        .expect("authorized");

    assert!(
        outcome_2.created_at > future,
        "a restarted store's first canvas-op timestamp ({}) must be seeded \
         past what this database already recorded ({future}), or a colliding \
         remove/clear right after a restart could share a fence with it",
        outcome_2.created_at
    );
}

/// The seed only has to run once per `Store`: after the first op, a
/// future-dated row planted straight into `canvas_ops` must be invisible to
/// later ops on the same instance. Monotonicity alone cannot prove that - a
/// reseed-on-every-call implementation is also monotonic (the 2026-08-11
/// review's test-quality finding), but it would adopt the planted timestamp
/// and jump ten minutes ahead, which the ceiling here refuses.
#[tokio::test]
async fn seeding_runs_once_and_later_calls_still_advance_monotonically() {
    let (store, pool, _guard) = new_store_and_pool().await;
    let (_token, actor) = register(&store, "root").await;
    let channel = general(&store).await;

    let object = place(&store, channel, actor, 0).await;
    let first_op = CanvasOpId::generate();
    let first = store
        .submit_canvas_op(
            channel,
            actor,
            first_op,
            true,
            CanvasOpRequest::Remove(vec![object]),
        )
        .await
        .expect("authorized");

    let planted = first.created_at + 10 * 60 * 1000;
    sqlx::query("UPDATE canvas_ops SET created_at = ? WHERE id = ?")
        .bind(planted)
        .bind(first_op)
        .execute(&pool)
        .await
        .unwrap();

    let mut previous = first.created_at;
    for _ in 0..4 {
        let object = place(&store, channel, actor, 0).await;
        let op_id = CanvasOpId::generate();
        let outcome = store
            .submit_canvas_op(
                channel,
                actor,
                op_id,
                true,
                CanvasOpRequest::Remove(vec![object]),
            )
            .await
            .expect("authorized");
        assert!(
            outcome.created_at > previous,
            "{} did not advance past {previous}",
            outcome.created_at
        );
        assert!(
            outcome.created_at < planted,
            "{} adopted the planted future row - the seed re-ran on a call              after the first",
            outcome.created_at
        );
        previous = outcome.created_at;
    }
}
