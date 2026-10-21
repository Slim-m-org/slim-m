// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Cross-channel isolation and the concurrency cases a single-threaded
//! script cannot reach.

use slimm_server::ids::{CanvasObjectId, CanvasOpId, UserId};
use slimm_server::store::{CanvasOpRequest, ClearScope, PlaceError, PlaceRequest, SubmitOpError};

use crate::fixtures::{self, general, new_store_and_pool, register};
use crate::repros::{place, replay_matches_live, submit};
use crate::script::Rng;

#[tokio::test]
async fn ids_from_another_channel_are_foreign_to_every_op() {
    let (store, _pool, _guard) = new_store_and_pool().await;
    let (_, actor) = register(&store, "root").await;
    let here = general(&store).await;
    let there = store.create_channel("elsewhere", "voice").await.unwrap().id;
    let foreign = place(&store, there, actor, "note").await;
    let erase = submit(&store, there, actor, CanvasOpRequest::Remove(vec![foreign]))
        .await
        .unwrap();

    let attempts = [
        CanvasOpRequest::Remove(vec![foreign]),
        CanvasOpRequest::Move {
            object_id: foreign,
            x: 1.0,
            y: 1.0,
            w: 1.0,
            h: 1.0,
        },
        CanvasOpRequest::Reorder {
            object_id: foreign,
            z_index: 9,
        },
        CanvasOpRequest::Edit {
            object_id: foreign,
            props: "{}".to_owned(),
        },
        CanvasOpRequest::Restore {
            target_op: erase.id,
        },
    ];
    for request in attempts {
        let outcome = submit(&store, here, actor, request).await;
        assert!(
            matches!(outcome, Err(SubmitOpError::NotFound)),
            "a foreign id was accepted"
        );
    }
    let request = PlaceRequest {
        kind: "stroke",
        bounds: (0.0, 0.0, 1.0, 1.0),
        props: "{}",
        attachment: None,
    };
    let placed = store
        .place_canvas_object(here, actor, foreign, request)
        .await;
    assert!(matches!(placed, Err(PlaceError::IdConflict)));
    let reuse = store
        .submit_canvas_op(
            here,
            actor,
            erase.id,
            true,
            CanvasOpRequest::Remove(vec![foreign]),
        )
        .await;
    assert!(
        matches!(reuse, Err(SubmitOpError::NotFound)),
        "an op id from another channel was replayed"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn racing_placements_never_overshoot_the_cap() {
    let (store, pool, _guard) = new_store_and_pool().await;
    let (_, w0) = register(&store, "root").await;
    let channel = general(&store).await;
    store.set_canvas_object_cap(100).await.unwrap();
    let mut tasks = Vec::new();
    for n in 0..160 {
        let store = store.clone();
        tasks.push(tokio::spawn(async move {
            let request = PlaceRequest {
                kind: "stroke",
                bounds: (n as f64, 0.0, 1.0, 1.0),
                props: "{}",
                attachment: None,
            };
            store
                .place_canvas_object(channel, w0, CanvasObjectId::generate(), request)
                .await
                .map(|p| p.fresh)
        }));
    }
    let mut placed = 0;
    for task in tasks {
        match task.await.unwrap() {
            Ok(true) => placed += 1,
            Ok(false) | Err(PlaceError::ChannelFull) => {}
            Err(other) => panic!("unexpected placement failure {other:?}"),
        }
    }
    let live: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM canvas_objects WHERE deleted_at IS NULL")
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!((placed, live), (100, 100));
    replay_matches_live(&store, channel).await.unwrap();
}

fn random_request(
    rng: &mut Rng,
    ids: &[CanvasObjectId],
    erasures: &[CanvasOpId],
    head: i64,
    authors: &[UserId],
) -> CanvasOpRequest {
    let pick = |rng: &mut Rng| ids[rng.below(ids.len() as u64) as usize];
    match rng.below(7) {
        0 | 1 => CanvasOpRequest::Remove(
            (0..1 + rng.below(3))
                .map(|_| pick(rng))
                .collect::<std::collections::BTreeSet<_>>()
                .into_iter()
                .collect(),
        ),
        2 => {
            let kinds = if rng.chance(50) {
                vec!["stroke".to_owned()]
            } else {
                Vec::new()
            };
            let author_id = rng
                .chance(30)
                .then(|| authors[rng.below(authors.len() as u64) as usize]);
            CanvasOpRequest::Clear {
                before_seq: rng.range(0, head + 5),
                scope: ClearScope { kinds, author_id },
            }
        }
        3 | 4 if !erasures.is_empty() => CanvasOpRequest::Restore {
            target_op: erasures[rng.below(erasures.len() as u64) as usize],
        },
        5 => CanvasOpRequest::Move {
            object_id: pick(rng),
            x: rng.range(-500, 500) as f64,
            y: rng.range(-500, 500) as f64,
            w: 20.0,
            h: 20.0,
        },
        _ => CanvasOpRequest::Reorder {
            object_id: pick(rng),
            z_index: rng.range(0, 10_000),
        },
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn racing_writers_keep_the_log_the_table_and_the_audit_trail_in_step() {
    for seed in 1..=6u64 {
        let (store, pool, _guard) = new_store_and_pool().await;
        let (_, w0) = register(&store, &format!("root{seed}")).await;
        let (_, w1) = fixtures::member(&store, &format!("bob{seed}")).await;
        let channel = general(&store).await;
        let authors = [w0, w1];
        let mut rng = Rng::new(seed);
        let mut ids = Vec::new();
        for n in 0..40 {
            ids.push(
                place(
                    &store,
                    channel,
                    authors[n % 2],
                    if n % 3 == 0 { "note" } else { "stroke" },
                )
                .await,
            );
        }
        let mut erasures = Vec::new();
        let mut audited = 0i64;
        for _ in 0..14 {
            let head = store
                .list_canvas_ops(channel, 0, 1)
                .await
                .unwrap()
                .latest_seq;
            let mut batch = Vec::new();
            for _ in 0..8 {
                let op = CanvasOpId::generate();
                let request = random_request(&mut rng, &ids, &erasures, head, &authors);
                batch.push((op, request_clone(&request)));
                if rng.chance(30) {
                    batch.push((op, request));
                }
            }
            let mut tasks = Vec::new();
            for (op, request) in batch {
                let store = store.clone();
                tasks.push(tokio::spawn(async move {
                    (
                        op,
                        store.submit_canvas_op(channel, w0, op, true, request).await,
                    )
                }));
            }
            let mut fresh_per_op = std::collections::HashMap::<CanvasOpId, u32>::new();
            for task in tasks {
                let (op, outcome) = task.await.unwrap();
                match outcome {
                    Ok(done) if done.fresh && done.affected > 0 => {
                        *fresh_per_op.entry(op).or_default() += 1;
                        if matches!(done.kind.as_str(), "remove" | "clear") {
                            erasures.push(op);
                        }
                        if matches!(done.kind.as_str(), "remove" | "clear" | "restore") {
                            audited += done.touched_ids.len() as i64;
                        }
                    }
                    Ok(_)
                    | Err(
                        SubmitOpError::NotFound
                        | SubmitOpError::NotAuthorized
                        | SubmitOpError::ChannelFull
                        | SubmitOpError::Locked,
                    ) => {}
                    Err(other) => panic!("seed {seed}: a racing op failed with {other:?}"),
                }
            }
            assert!(
                fresh_per_op.values().all(|n| *n == 1),
                "seed {seed}: one op id applied twice: {fresh_per_op:?}"
            );
            replay_matches_live(&store, channel)
                .await
                .unwrap_or_else(|e| panic!("seed {seed}: {e}"));
            let rows: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM canvas_audit_log")
                .fetch_one(&pool)
                .await
                .unwrap();
            assert_eq!(rows, audited, "seed {seed}: audit rows vs touched objects");
            let seqs: Vec<i64> = sqlx::query_scalar("SELECT seq FROM canvas_ops ORDER BY seq")
                .fetch_all(&pool)
                .await
                .unwrap();
            assert!(
                seqs.iter().enumerate().all(|(i, s)| *s == i as i64 + 1),
                "seed {seed}: the log has a gap"
            );
        }
    }
}

fn request_clone(request: &CanvasOpRequest) -> CanvasOpRequest {
    match request {
        CanvasOpRequest::Remove(ids) => CanvasOpRequest::Remove(ids.clone()),
        CanvasOpRequest::Clear { before_seq, scope } => CanvasOpRequest::Clear {
            before_seq: *before_seq,
            scope: scope.clone(),
        },
        CanvasOpRequest::Restore { target_op } => CanvasOpRequest::Restore {
            target_op: *target_op,
        },
        CanvasOpRequest::Move {
            object_id,
            x,
            y,
            w,
            h,
        } => CanvasOpRequest::Move {
            object_id: *object_id,
            x: *x,
            y: *y,
            w: *w,
            h: *h,
        },
        CanvasOpRequest::Reorder { object_id, z_index } => CanvasOpRequest::Reorder {
            object_id: *object_id,
            z_index: *z_index,
        },
        CanvasOpRequest::Edit { object_id, props } => CanvasOpRequest::Edit {
            object_id: *object_id,
            props: props.clone(),
        },
    }
}
