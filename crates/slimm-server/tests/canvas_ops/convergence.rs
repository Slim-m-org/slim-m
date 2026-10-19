// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Concurrency property test for the server's own materialization: real
//! concurrent `move`/`remove`/`restore` submissions must never leave
//! `canvas_ops` (the durable log) disagreeing with `canvas_objects` (the
//! live table), and two racing submissions of the identical `op_id` must
//! serialize to exactly one stored op.
//!
//! This is the complementary half of
//! `client/packages/app/test/canvas_convergence_property_test.dart`, and it
//! checks a different thing: that one does client-side delivery-order
//! resilience against a fixed canonical log, this checks that the log is
//! ever produced correctly under real concurrent writers in the first
//! place. Neither test can stand in for the other.

use std::collections::HashMap;

use slimm_server::ids::{CanvasObjectId, ChannelId, UserId};
use slimm_server::store::{CanvasOpBody, CanvasOpRequest, Store};

use crate::fixtures::{general, new_store_and_pool, place, register};

type Bounds = (f64, f64, f64, f64);

/// Replays a channel's whole `canvas_ops` feed into what it says the alive
/// set and each object's bounds should be, with no reference to
/// `canvas_objects` at all - an independent reducer over the durable log,
/// the same role the client's own oracle plays over the wire log.
async fn replay_log(store: &Store, channel: ChannelId) -> HashMap<CanvasObjectId, Bounds> {
    let mut placed: HashMap<CanvasObjectId, (i64, Bounds)> = HashMap::new();
    let mut dead: std::collections::HashSet<CanvasObjectId> = std::collections::HashSet::new();
    let mut after = 0;
    loop {
        let page = store.list_canvas_ops(channel, after, 500).await.unwrap();
        assert!(!page.reset, "a fresh, uncompacted log must never reset");
        for op in &page.ops {
            match &op.body {
                CanvasOpBody::Place(Some(obj)) => {
                    placed.insert(obj.id, (obj.seq.0, (obj.x, obj.y, obj.w, obj.h)));
                }
                CanvasOpBody::Place(None) => {}
                CanvasOpBody::Remove(ids) => {
                    dead.extend(ids.iter().copied());
                }
                CanvasOpBody::Clear { before_seq } => {
                    for (id, (seq, _)) in &placed {
                        if *seq <= *before_seq {
                            dead.insert(*id);
                        }
                    }
                }
                CanvasOpBody::Restore { object_ids, .. } => {
                    for id in object_ids {
                        dead.remove(id);
                    }
                }
                CanvasOpBody::Move {
                    object_id,
                    x,
                    y,
                    w,
                    h,
                } => {
                    if let Some(entry) = placed.get_mut(object_id) {
                        entry.1 = (*x, *y, *w, *h);
                    }
                }
                // Reorder moves z_index only, which this reducer does not model; see its doc.
                CanvasOpBody::Reorder { .. } | CanvasOpBody::Edit { .. } => {}
            }
        }
        if page.has_more {
            after = page.ops.last().unwrap().seq;
        } else {
            break;
        }
    }
    placed
        .into_iter()
        .filter(|(id, _)| !dead.contains(id))
        .map(|(id, (_, bounds))| (id, bounds))
        .collect()
}

/// The live `canvas_objects` table's own answer, read directly with no
/// shared code path with [`replay_log`].
async fn live_table(
    pool: &sqlx::SqlitePool,
    channel: ChannelId,
) -> HashMap<CanvasObjectId, Bounds> {
    let rows: Vec<(CanvasObjectId, f64, f64, f64, f64)> = sqlx::query_as(
        "SELECT id, x, y, w, h FROM canvas_objects
         WHERE channel_id = ? AND deleted_at IS NULL",
    )
    .bind(channel)
    .fetch_all(pool)
    .await
    .unwrap();
    rows.into_iter()
        .map(|(id, x, y, w, h)| (id, (x, y, w, h)))
        .collect()
}

async fn submit(
    store: &Store,
    channel: ChannelId,
    actor: UserId,
    request: CanvasOpRequest,
) -> String {
    store
        .submit_canvas_op(
            channel,
            actor,
            slimm_server::ids::CanvasOpId::generate(),
            true,
            request,
        )
        .await
        .map(|op| op.kind)
        .unwrap_or_else(|err| panic!("every submission in this test is authorized: {err:?}"))
}

/// Fires a deliberately overlapping batch of `move`, `remove` and `restore`
/// requests at the same channel concurrently, then asserts the durable log
/// and the live table agree, across a few seeds so the overlap pattern
/// itself varies rather than being one hand-picked case.
#[tokio::test]
async fn concurrent_moves_removes_and_restores_never_desync_the_log_from_the_table() {
    for seed in 0..5u64 {
        let (store, pool, _guard) = new_store_and_pool().await;
        let (_, actor) = register(&store, &format!("root{seed}")).await;
        let channel = general(&store).await;

        let ids: Vec<CanvasObjectId> = {
            let mut v = Vec::new();
            for _ in 0..12 {
                v.push(place(&store, channel, actor, 0).await);
            }
            v
        };

        // Two overlapping removes: [0,1] and [1,2], both naming id 1.
        let remove_a = CanvasOpRequest::Remove(vec![ids[0], ids[1]]);
        let remove_b = CanvasOpRequest::Remove(vec![ids[1], ids[2]]);
        // Two concurrent moves racing for the same object.
        let move_a = CanvasOpRequest::Move {
            object_id: ids[3],
            x: 10.0 + seed as f64,
            y: 10.0,
            w: 5.0,
            h: 5.0,
        };
        let move_b = CanvasOpRequest::Move {
            object_id: ids[3],
            x: 20.0 + seed as f64,
            y: 20.0,
            w: 5.0,
            h: 5.0,
        };
        // A clear over the first few placements, raced against a move on one of the objects it kills.
        let clear = CanvasOpRequest::Clear { before_seq: 5 };
        let move_c = CanvasOpRequest::Move {
            object_id: ids[4],
            x: 1.0,
            y: 1.0,
            w: 5.0,
            h: 5.0,
        };

        let mut tasks = Vec::new();
        for request in [remove_a, remove_b, move_a, move_b, clear, move_c] {
            let store = store.clone();
            tasks.push(tokio::spawn(async move {
                submit(&store, channel, actor, request).await
            }));
        }
        futures_util::future::join_all(tasks)
            .await
            .into_iter()
            .for_each(|r| {
                r.expect("task panicked");
            });

        // A remove of the tail objects, raced against a restore of the earlier clear.
        let remove_tail = CanvasOpRequest::Remove(vec![ids[10], ids[11]]);
        let restore_clear = CanvasOpRequest::Restore {
            target_op: find_clear_op(&store, channel).await,
        };
        let store_a = store.clone();
        let store_b = store.clone();
        let (r1, r2) = tokio::join!(
            tokio::spawn(async move { submit(&store_a, channel, actor, remove_tail).await }),
            tokio::spawn(async move { submit(&store_b, channel, actor, restore_clear).await }),
        );
        r1.expect("task panicked");
        r2.expect("task panicked");

        let log_state = replay_log(&store, channel).await;
        let table_state = live_table(&pool, channel).await;
        assert_eq!(
            log_state.len(),
            table_state.len(),
            "seed {seed}: alive count must match between log and table"
        );
        for (id, bounds) in &table_state {
            let from_log = log_state.get(id).unwrap_or_else(|| {
                panic!("seed {seed}: {id} is live but absent from the log replay")
            });
            assert!(
                (from_log.0 - bounds.0).abs() < 1e-9 && (from_log.1 - bounds.1).abs() < 1e-9,
                "seed {seed}: {id} position disagrees between log and table"
            );
        }

        assert_dense_ops(&store, channel).await;
    }
}

/// The channel's own `canvas_ops` must page as one dense run with no gaps,
/// which every reader (a resuming client, this test's own [`replay_log`])
/// depends on.
async fn assert_dense_ops(store: &Store, channel: ChannelId) {
    let mut after = 0;
    let mut count = 0i64;
    loop {
        let page = store.list_canvas_ops(channel, after, 500).await.unwrap();
        assert!(!page.reset);
        for op in &page.ops {
            count += 1;
            assert_eq!(op.seq, count, "the log must be dense with no gaps");
        }
        if page.has_more {
            after = page.ops.last().unwrap().seq;
        } else {
            assert_eq!(count, page.latest_seq, "every allocated seq has a row");
            break;
        }
    }
}

async fn find_clear_op(store: &Store, channel: ChannelId) -> slimm_server::ids::CanvasOpId {
    let page = store.list_canvas_ops(channel, 0, 500).await.unwrap();
    page.ops
        .into_iter()
        .find_map(|op| matches!(op.body, CanvasOpBody::Clear { .. }).then_some(op.id))
        .expect("the batch above always submits exactly one clear")
}

/// Two tasks submit the identical `op_id` concurrently - the shape a
/// network retry racing its own original request produces. Single-writer
/// SQLite serializes the two transactions; the loser must read back the
/// winner's own stored op rather than allocating a second seq.
#[tokio::test]
async fn a_racing_duplicate_op_id_serializes_to_one_stored_op() {
    let (store, _pool, _guard) = new_store_and_pool().await;
    let (_, actor) = register(&store, "root").await;
    let channel = general(&store).await;
    let object = place(&store, channel, actor, 0).await;
    let op_id = slimm_server::ids::CanvasOpId::generate();

    let store_a = store.clone();
    let store_b = store.clone();
    let (a, b) = tokio::join!(
        tokio::spawn(async move {
            let request = CanvasOpRequest::Remove(vec![object]);
            store_a
                .submit_canvas_op(channel, actor, op_id, true, request)
                .await
        }),
        tokio::spawn(async move {
            let request = CanvasOpRequest::Remove(vec![object]);
            store_b
                .submit_canvas_op(channel, actor, op_id, true, request)
                .await
        }),
    );
    let a = a.expect("task panicked").expect("authorized");
    let b = b.expect("task panicked").expect("authorized");

    assert_eq!(
        a.seq, b.seq,
        "both calls must agree on the one seq allocated"
    );
    assert_eq!(a.affected, b.affected);
    assert_ne!(
        a.fresh, b.fresh,
        "exactly one of the two racing calls wrote the row"
    );

    let page = store.list_canvas_ops(channel, 0, 10).await.unwrap();
    assert_eq!(
        page.ops.iter().filter(|op| op.id == op_id).count(),
        1,
        "the racing duplicate must not have produced a second row"
    );
}
