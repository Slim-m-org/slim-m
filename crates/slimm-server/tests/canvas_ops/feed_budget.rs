// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The catch-up feed's page-byte budget, split out of `feed.rs` once these
//! tests and their shared seed helpers pushed that file past the 500-line
//! hard ceiling.

use uuid::Uuid;

use slimm_server::ids::{ChannelId, UserId};
use slimm_server::store::{CANVAS_OP_PAGE_BYTES, CanvasOpBody};

use crate::fixtures::{new_store, new_store_and_pool, place, place_many};
use crate::support::canvas::CanvasReads;

/// A page bounded only by row count still varies three orders of magnitude
/// in bytes, since a `place` op carries whole props at up to `MAX_PROPS_BYTES`
/// while every other kind is capped small or (see the two tests below)
/// merely bounded by `MAX_OBJECTS_PER_CHANNEL` rather than never mattering.
#[tokio::test]
async fn a_page_stops_early_once_place_props_cross_the_byte_budget() {
    let (store, _guard) = new_store().await;
    let author = store.create_user("ann", "Ann").await.unwrap().id;
    let channel = store.create_channel("canvas", "voice").await.unwrap().id;

    // Comfortably past MAX_PROPS_BYTES (4 KiB) each, so well under 140 crosses CANVAS_OP_PAGE_BYTES.
    let placed_count = 140;
    for _ in 0..placed_count {
        place(&store, channel, author, 4_000).await;
    }

    let page = store.list_canvas_ops(channel, 0, 200).await.unwrap();
    assert!(
        page.ops.len() < placed_count,
        "the byte budget must stop the page before the row limit, got {} ops",
        page.ops.len()
    );
    assert!(page.has_more, "a budget-truncated page must say so");

    let total_bytes: usize = page
        .ops
        .iter()
        .map(|op| match &op.body {
            CanvasOpBody::Place(Some(object)) => object.props.len(),
            _ => 0,
        })
        .sum();
    assert!(
        total_bytes <= CANVAS_OP_PAGE_BYTES + 4_100,
        "the page must not run far past the byte budget: {total_bytes} bytes"
    );
}

/// Closed residual: `restore`'s own `canvas_op_targets` rows now count
/// toward the page budget too, roughly 40 bytes apiece, so a `restore` of a
/// large `clear` pages the same way a run of oversized
/// `place` ops already did rather than being dumped whole into one response.
/// `clear` keeps no per-call cap on how many objects it may touch (a
/// channel-wide clear has to stay one cheap write), so restoring it can
/// still un-delete up to `MAX_OBJECTS_PER_CHANNEL` objects in one op - the
/// budget cannot shrink that op below its own size without either capping
/// a clear-restore (breaking "undo a mass clear in one action") or splitting
/// one op's targets across pages (a bigger wire-shape change). What it can
/// do, and now does, is stop this op from being handed out bundled with
/// others: the first row of a page is still force-included regardless of
/// size, the same guarantee `place` relies on to avoid a livelock, but nothing
/// after it may ride along for free.
#[tokio::test]
async fn a_restore_that_would_blow_the_page_budget_pages_rather_than_bundles() {
    let (store, pool, _guard) = new_store_and_pool().await;
    let author = store.create_user("ann", "Ann").await.unwrap().id;
    let channel = store.create_channel("canvas", "voice").await.unwrap().id;
    let target_op = seed_remove_op(&pool, channel, author, 1).await;
    let touched_count = seed_restore_op(&pool, channel, author, 2, target_op, 15_000).await;
    advance_canvas_counter(&pool, channel, 3).await;

    // Bundled with the cheap remove ahead of it, this op alone must not fit.
    let first = store.list_canvas_ops(channel, 0, 200).await.unwrap();
    assert_eq!(
        first.ops.len(),
        1,
        "the restore must not ride along with the op ahead of it"
    );
    assert!(
        first.has_more,
        "the restore is still to come on a later page"
    );

    // Force-included once it leads its own page, the same guarantee `place` relies on.
    let second = store.list_canvas_ops(channel, 1, 200).await.unwrap();
    assert_eq!(
        second.ops.len(),
        1,
        "a lone oversized op must still advance"
    );
    assert!(!second.has_more);
    let restored_count = match &second.ops[0].body {
        CanvasOpBody::Restore { object_ids, .. } => object_ids.len(),
        other => panic!("expected Restore, got {other:?}"),
    };
    assert_eq!(restored_count as i64, touched_count);
}

/// The aggravated shape the test above does not reach: nothing before this
/// fix stopped *several* oversized `restore` ops from compounding into one
/// response, since the budget loop's `bytes` term was always zero for every
/// kind but `place`. Three 15,000-id restores back to back used to answer in
/// one page at roughly 38 bytes/id, well past the 512 KiB budget three times
/// over; each now lands on its own page.
#[tokio::test]
async fn several_large_restores_do_not_compound_in_one_page() {
    let (store, pool, _guard) = new_store_and_pool().await;
    let author = store.create_user("ann", "Ann").await.unwrap().id;
    let channel = store.create_channel("canvas", "voice").await.unwrap().id;
    let target_op = seed_remove_op(&pool, channel, author, 1).await;
    seed_restore_op(&pool, channel, author, 2, target_op, 15_000).await;
    seed_restore_op(&pool, channel, author, 3, target_op, 15_000).await;
    seed_restore_op(&pool, channel, author, 4, target_op, 15_000).await;
    advance_canvas_counter(&pool, channel, 5).await;

    let mut after_seq = 0;
    let mut pages = Vec::new();
    loop {
        let page = store
            .list_canvas_ops(channel, after_seq, 200)
            .await
            .unwrap();
        let has_more = page.has_more;
        after_seq = page.ops.last().map_or(after_seq, |op| op.seq);
        pages.push(page.ops.len());
        if !has_more {
            break;
        }
    }
    assert_eq!(
        pages,
        vec![1, 1, 1, 1],
        "each op, cheap or oversized, must land alone rather than bundled: {pages:?}"
    );
}

/// Seeds a `remove` op with no targets - cheap, the same shape a real erase
/// with nothing left to restore would leave behind - and returns its id for
/// a `restore` to reference.
async fn seed_remove_op(
    pool: &sqlx::SqlitePool,
    channel: ChannelId,
    author: UserId,
    seq: i64,
) -> Uuid {
    sqlx::query(
        "INSERT INTO canvas_ops (channel_id, seq, id, kind, actor_id, created_at)
         VALUES (?, ?, randomblob(16), 'remove', ?, 0)",
    )
    .bind(channel)
    .bind(seq)
    .bind(author)
    .execute(pool)
    .await
    .expect("seed a remove op");
    sqlx::query_scalar("SELECT id FROM canvas_ops WHERE channel_id = ? AND seq = ?")
        .bind(channel)
        .bind(seq)
        .fetch_one(pool)
        .await
        .unwrap()
}

/// Seeds a `restore` op at `seq` naming `touched_count` real objects -
/// `canvas_op_targets.object_id` is a genuine FK onto `canvas_objects`, and
/// the same object ids are reused across every call so seeding several large
/// restores stays cheap. Returns the touched count for the caller to assert
/// against.
async fn seed_restore_op(
    pool: &sqlx::SqlitePool,
    channel: ChannelId,
    author: UserId,
    seq: i64,
    target_op: Uuid,
    touched_count: i64,
) -> i64 {
    sqlx::query(
        "INSERT INTO canvas_ops (channel_id, seq, id, kind, actor_id, target_op, created_at)
         VALUES (?, ?, randomblob(16), 'restore', ?, ?, 0)",
    )
    .bind(channel)
    .bind(seq)
    .bind(author)
    .bind(target_op)
    .execute(pool)
    .await
    .expect("seed the restore op");

    let existing: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM canvas_objects WHERE channel_id = ?")
            .bind(channel)
            .fetch_one(pool)
            .await
            .unwrap();
    if existing < touched_count {
        sqlx::query(
            "WITH RECURSIVE n(i) AS (SELECT ? UNION ALL SELECT i + 1 FROM n WHERE i < ?)
             INSERT INTO canvas_objects
                 (id, channel_id, channel_key, kind, z_index, x, y, w, h, props,
                  author_id, seq, created_at)
             SELECT randomblob(16), ?, 0, 'stroke', i, 0, 0, 1, 1, '{}', ?, i, 0 FROM n",
        )
        .bind(existing + 1)
        .bind(touched_count)
        .bind(channel)
        .bind(author)
        .execute(pool)
        .await
        .expect("seed objects for the restore to name");
    }
    sqlx::query(
        "INSERT INTO canvas_op_targets (channel_id, seq, object_id)
         SELECT channel_id, ?, id FROM canvas_objects WHERE channel_id = ? LIMIT ?",
    )
    .bind(seq)
    .bind(channel)
    .bind(touched_count)
    .execute(pool)
    .await
    .expect("seed the restore's touched ids");
    touched_count
}

async fn advance_canvas_counter(pool: &sqlx::SqlitePool, channel: ChannelId, next_seq: i64) {
    sqlx::query(
        "UPDATE channel_seq_counters SET next_seq = ? WHERE channel_id = ? AND stream = 'canvas'",
    )
    .bind(next_seq)
    .bind(channel)
    .execute(pool)
    .await
    .expect("advance the counter to match");
}

/// A `clear`'s own wire body is `{before_seq}`, never an `object_ids` list -
/// unlike `remove`, `restore`, `move` and `reorder`, none of which this test
/// touches. Before this fix, the shared `canvas_op_targets` insert loop in
/// `submit_canvas_op` ran for every kind alike, so a `clear` touching many
/// objects wrote one row per object into a table nothing reads back for it:
/// `restore_candidates`'s own `clear` branch reads the `deleted_at` fence,
/// not this table, and `list_canvas_ops`'s `clear` body never serializes an
/// object list either. Those rows were dead weight with one live cost -
/// `list_canvas_ops`'s page-byte budget prices every non-`place` kind's
/// `canvas_op_targets` rows as if they were that kind's own wire payload
/// (true for `remove`/`restore`/`move`/`reorder`, never true for `clear`),
/// so a large `clear` was priced as if it carried an object list its DTO
/// never has, needlessly forcing it onto its own page.
#[tokio::test]
async fn a_clear_writes_no_target_rows_and_costs_nothing_in_the_page_budget() {
    let (store, pool, _guard) = new_store_and_pool().await;
    let author = store.create_user("ann", "Ann").await.unwrap().id;
    let channel = store.create_channel("canvas", "voice").await.unwrap().id;

    // Comfortably past what CANVAS_OP_TARGET_BYTES_ESTIMATE would need to blow the budget alone.
    let touched = 15_000;
    place_many(&pool, channel, author, touched).await;
    let latest = store.latest_canvas_seq(channel).await.unwrap();

    let clear_outcome = store
        .submit_canvas_op(
            channel,
            author,
            slimm_server::ids::CanvasOpId::generate(),
            true,
            slimm_server::store::CanvasOpRequest::Clear { before_seq: latest },
        )
        .await
        .unwrap();
    assert_eq!(clear_outcome.affected, touched);

    let target_rows: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM canvas_op_targets WHERE channel_id = ? AND seq = ?",
    )
    .bind(channel)
    .bind(clear_outcome.seq)
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(
        target_rows, 0,
        "a clear must write no canvas_op_targets rows"
    );

    // A cheap place right after must bundle with the clear: its wire cost is one integer, not 15,000 ids.
    place(&store, channel, author, 0).await;
    let page = store
        .list_canvas_ops(channel, latest - 1, 200)
        .await
        .unwrap();
    assert!(
        page.ops.len() >= 3,
        "the clear must not be priced as if it carried an object list: got {} ops",
        page.ops.len()
    );
}
