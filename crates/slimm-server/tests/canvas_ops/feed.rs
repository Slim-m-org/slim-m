// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The store side of the feed: object liveness, the three reset triggers,
//! pagination, and anonymization on account deletion. The page-byte budget
//! has its own sibling module, `feed_budget`.

use std::fs;
use std::path::Path;

use uuid::Uuid;

use slimm_server::store::{CANVAS_OP_GAP, CanvasOpBody};

use crate::fixtures::{new_store, new_store_and_pool, place};
use crate::support::canvas::remove_via_op;

#[tokio::test]
async fn a_place_ops_object_is_present_and_matches_what_was_placed() {
    let (store, _guard) = new_store().await;
    let author = store.create_user("ann", "Ann").await.unwrap().id;
    let channel = store.create_channel("canvas", "voice").await.unwrap().id;
    let placed = place(&store, channel, author, 0).await;

    let page = store.list_canvas_ops(channel, 0, 100).await.unwrap();
    assert_eq!(page.ops.len(), 1);
    match &page.ops[0].body {
        CanvasOpBody::Place(Some(object)) => assert_eq!(object.id, placed),
        other => panic!("expected a live place object, got {other:?}"),
    }
}

/// The subtlest line in the design: a `place` whose object has since been
/// removed carries no `object` at all, so a client never repaints something
/// the server no longer holds live.
#[tokio::test]
async fn a_place_ops_object_is_absent_once_the_object_has_been_removed() {
    let (store, _guard) = new_store().await;
    let author = store.create_user("ann", "Ann").await.unwrap().id;
    let channel = store.create_channel("canvas", "voice").await.unwrap().id;
    let placed = place(&store, channel, author, 0).await;
    remove_via_op(&store, channel, author, placed).await;

    let page = store.list_canvas_ops(channel, 0, 100).await.unwrap();
    assert_eq!(page.ops.len(), 2, "the place op survives the removal op");
    match &page.ops[0].body {
        CanvasOpBody::Place(None) => {}
        other => panic!("expected the object to read as gone, got {other:?}"),
    }
    assert!(matches!(&page.ops[1].body, CanvasOpBody::Remove(ids) if ids == &[placed]));
}

/// Nothing writes a `remove`, `clear` or `restore` op yet, but the schema's
/// own CHECK constraints already admit all four kinds, so the feed's read
/// side is built to serialize every one of them now rather than only once a
/// later PR adds a way to write them. Raw SQL stands in for that future
/// write path, testing the read side generically ahead of it.
#[tokio::test]
async fn the_feed_serializes_every_kind_the_schema_admits() {
    let (store, pool, _guard) = new_store_and_pool().await;
    let author = store.create_user("ann", "Ann").await.unwrap().id;
    let channel = store.create_channel("canvas", "voice").await.unwrap().id;
    let placed = place(&store, channel, author, 0).await; // seq 1

    let remove_op = Uuid::now_v7();
    sqlx::query(
        "INSERT INTO canvas_ops (channel_id, seq, id, kind, actor_id, created_at)
         VALUES (?, 2, ?, 'remove', ?, 0)",
    )
    .bind(channel)
    .bind(remove_op)
    .bind(author)
    .execute(&pool)
    .await
    .expect("seed a remove op");
    sqlx::query("INSERT INTO canvas_op_targets (channel_id, seq, object_id) VALUES (?, 2, ?)")
        .bind(channel)
        .bind(placed)
        .execute(&pool)
        .await
        .expect("seed the remove op's target");

    sqlx::query(
        "INSERT INTO canvas_ops (channel_id, seq, id, kind, actor_id, bound_seq, created_at)
         VALUES (?, 3, randomblob(16), 'clear', ?, 1, 0)",
    )
    .bind(channel)
    .bind(author)
    .execute(&pool)
    .await
    .expect("seed a clear op");

    sqlx::query(
        "INSERT INTO canvas_ops (channel_id, seq, id, kind, actor_id, target_op, created_at)
         VALUES (?, 4, randomblob(16), 'restore', ?, ?, 0)",
    )
    .bind(channel)
    .bind(author)
    .bind(remove_op)
    .execute(&pool)
    .await
    .expect("seed a restore op");
    sqlx::query("INSERT INTO canvas_op_targets (channel_id, seq, object_id) VALUES (?, 4, ?)")
        .bind(channel)
        .bind(placed)
        .execute(&pool)
        .await
        .expect("seed the restore op's target");
    sqlx::query(
        "UPDATE channel_seq_counters SET next_seq = 5 WHERE channel_id = ? AND stream = 'canvas'",
    )
    .bind(channel)
    .execute(&pool)
    .await
    .expect("advance the counter to match");

    let page = store.list_canvas_ops(channel, 0, 100).await.unwrap();
    assert_eq!(page.ops.len(), 4);

    match &page.ops[1].body {
        CanvasOpBody::Remove(ids) => assert_eq!(ids, &[placed]),
        other => panic!("expected Remove, got {other:?}"),
    }
    match &page.ops[2].body {
        CanvasOpBody::Clear { before_seq } => assert_eq!(*before_seq, 1),
        other => panic!("expected Clear, got {other:?}"),
    }
    match &page.ops[3].body {
        CanvasOpBody::Restore {
            target_op,
            object_ids,
        } => {
            assert_eq!(*target_op, slimm_server::ids::CanvasOpId(remove_op));
            assert_eq!(object_ids, &[placed]);
        }
        other => panic!("expected Restore, got {other:?}"),
    }
}

#[tokio::test]
async fn the_feed_resets_when_the_cursor_is_ahead_of_latest_seq() {
    let (store, _guard) = new_store().await;
    let author = store.create_user("ann", "Ann").await.unwrap().id;
    let channel = store.create_channel("canvas", "voice").await.unwrap().id;
    place(&store, channel, author, 0).await;

    let page = store.list_canvas_ops(channel, 100, 100).await.unwrap();
    assert!(page.reset, "after_seq past latest_seq must reset");
    assert_eq!(page.latest_seq, 1);
    assert!(page.ops.is_empty());
}

#[tokio::test]
async fn the_feed_resets_when_the_caller_is_too_far_behind() {
    let (store, pool, _guard) = new_store_and_pool().await;
    let author = store.create_user("ann", "Ann").await.unwrap().id;
    let channel = store.create_channel("canvas", "voice").await.unwrap().id;

    let total = CANVAS_OP_GAP + 5;
    sqlx::query(
        "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < ?)
         INSERT INTO canvas_ops (channel_id, seq, id, kind, actor_id, created_at)
         SELECT ?, i, randomblob(16), 'place', ?, 0 FROM n",
    )
    .bind(total)
    .bind(channel)
    .bind(author)
    .execute(&pool)
    .await
    .expect("seed the op stream");
    sqlx::query(
        "UPDATE channel_seq_counters SET next_seq = ? WHERE channel_id = ? AND stream = 'canvas'",
    )
    .bind(total + 1)
    .bind(channel)
    .execute(&pool)
    .await
    .expect("advance the counter to match");

    let page = store.list_canvas_ops(channel, 0, 100).await.unwrap();
    assert!(page.reset, "more than CANVAS_OP_GAP behind must reset");
    assert_eq!(page.latest_seq, total);
    assert!(page.ops.is_empty());
}

/// Simulates a future sweep by raw-deleting the earliest ops (nothing in
/// this slice does this yet), and checks the boundary precisely: one op
/// short of the floor resets, exactly caught up to it does not.
#[tokio::test]
async fn the_feed_resets_only_strictly_behind_the_retained_floor() {
    let (store, pool, _guard) = new_store_and_pool().await;
    let author = store.create_user("ann", "Ann").await.unwrap().id;
    let channel = store.create_channel("canvas", "voice").await.unwrap().id;
    for _ in 0..5 {
        place(&store, channel, author, 0).await;
    }
    sqlx::query("DELETE FROM canvas_ops WHERE channel_id = ? AND seq <= 2")
        .bind(channel)
        .execute(&pool)
        .await
        .expect("simulate a sweep raising the floor to 3");

    let behind = store.list_canvas_ops(channel, 1, 100).await.unwrap();
    assert!(behind.reset, "one op short of the floor is unrecoverable");
    assert!(behind.ops.is_empty());

    let at_floor = store.list_canvas_ops(channel, 2, 100).await.unwrap();
    assert!(
        !at_floor.reset,
        "exactly caught up to the floor must not reset"
    );
    assert_eq!(at_floor.ops[0].seq, 3);
}

/// The opposite end from the viewport read's own over-read trim: this feed
/// reads oldest-first, so a truncated page drops the newest row, and paging
/// forward from the last seq returned reaches every op with no gap or
/// repeat.
#[tokio::test]
async fn has_more_is_dropped_from_the_back_and_paging_continues_correctly() {
    let (store, _guard) = new_store().await;
    let author = store.create_user("ann", "Ann").await.unwrap().id;
    let channel = store.create_channel("canvas", "voice").await.unwrap().id;
    for _ in 0..5 {
        place(&store, channel, author, 0).await;
    }

    let first = store.list_canvas_ops(channel, 0, 2).await.unwrap();
    assert_eq!(
        first.ops.iter().map(|o| o.seq).collect::<Vec<_>>(),
        vec![1, 2]
    );
    assert!(first.has_more);

    let second = store.list_canvas_ops(channel, 2, 2).await.unwrap();
    assert_eq!(
        second.ops.iter().map(|o| o.seq).collect::<Vec<_>>(),
        vec![3, 4]
    );
    assert!(second.has_more);

    let third = store.list_canvas_ops(channel, 4, 2).await.unwrap();
    assert_eq!(third.ops.iter().map(|o| o.seq).collect::<Vec<_>>(), vec![5]);
    assert!(!third.has_more);
}

#[tokio::test]
async fn account_deletion_nulls_the_actor_id_of_a_placed_op() {
    let (store, _guard) = new_store().await;
    let author = store.create_user("ann", "Ann").await.unwrap().id;
    let channel = store.create_channel("canvas", "voice").await.unwrap().id;
    place(&store, channel, author, 0).await;

    store.delete_account(author).await.unwrap();

    let page = store.list_canvas_ops(channel, 0, 100).await.unwrap();
    assert_eq!(
        page.ops[0].actor_id, None,
        "a deleted account must not stay named as the actor of a canvas op"
    );
}

/// The page and its `latest_seq` share one snapshot only if every read in
/// `list_canvas_ops` goes through the transaction it opens, never `&self.pool`
/// directly. A race between two real async tasks is not a reliable way to
/// catch a regression here (SQLite's own writes are fast enough that the
/// window rarely lands), so this reads the source the way
/// `canvas_index.rs` reads the viewport query rather than timing anything.
///
/// It reads the scrubbed source rather than the raw file: unscrubbed, a doc
/// comment explaining why a direct pool read would be wrong is itself enough
/// to satisfy the check that no direct pool read exists. The whole file stays
/// in scope rather than being narrowed to this one function, which would
/// scrub the comments too and quietly drop every other function from the
/// check.
#[test]
fn the_ops_feed_reads_only_through_one_transaction() {
    let raw =
        fs::read_to_string(Path::new(env!("CARGO_MANIFEST_DIR")).join("src/store/canvas_ops.rs"))
            .expect("read the canvas ops store module");
    let source = crate::support::code_only(&raw);
    assert!(
        !source.contains("&self.pool"),
        "a direct pool read here would race the transaction the feed's snapshot depends on"
    );
    assert_eq!(
        source.matches("self.begin_read()").count(),
        1,
        "the feed must open exactly one transaction for its floor, latest_seq and page reads"
    );
}
