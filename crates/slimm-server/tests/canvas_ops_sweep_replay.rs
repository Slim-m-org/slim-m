// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A busy channel, seeded rather than empty, replayed after a sweep.
//!
//! Split out of `canvas_ops_sweep.rs` to keep that file under the review
//! budget; this is the one scenario in the pair that needs a real reducer
//! rather than a handful of direct assertions. Fixtures are duplicated
//! rather than shared, the same choice every other pair of canvas test
//! binaries in this crate already makes: integration test binaries do not
//! link against each other.

use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ids::{CanvasObjectId, CanvasOpId, ChannelId, UserId};
use slimm_server::store::{CanvasOpBody, CanvasOpRequest, PlaceRequest, Store};
use sqlx::SqlitePool;
use std::collections::{HashMap, HashSet};

mod support;

use support::app::register_id as register;

const DAY_MS: i64 = 24 * 60 * 60 * 1000;
const AGE_DAYS: i64 = 31;

async fn harness() -> (Store, SqlitePool, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new("slimm-canvas-ops-sweep-replay");
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

/// See `canvas_ops_sweep.rs`'s own copy of this helper: `canvas_objects.deleted_at`
/// has to age in step, or a clear's exact-timestamp guard desyncs.
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

/// A busy channel with a realistic mix - two fully undone remove/restore
/// pairs old enough to sweep, one still-dead remove that must survive
/// forever, and a clear with one live target - swept once, then replayed
/// from the surviving log alone with no reference to `canvas_objects`. The
/// replay must agree with the live table exactly: this is the property a
/// sweep that deletes the wrong thing would break silently.
///
/// The clear goes first, on the channel's only object so far: `Clear` kills
/// everything still alive at or below its fence channel-wide, so everything
/// placed afterward has to stay above that fence.
#[tokio::test]
async fn a_seeded_channel_replays_correctly_after_a_sweep() {
    let (store, pool, _guard) = harness().await;
    let actor = register(&store, "root").await;
    let channel = general(&store).await;

    // The clear must run first; see the module-level test doc above.
    let cleared_live = place(&store, channel, actor).await;
    let head = store
        .list_canvas_ops(channel, 0, 1)
        .await
        .unwrap()
        .latest_seq;
    submit(
        &store,
        channel,
        actor,
        CanvasOpRequest::Clear { before_seq: head },
    )
    .await;

    let undone_a = place(&store, channel, actor).await;
    let remove_undone_a = submit(
        &store,
        channel,
        actor,
        CanvasOpRequest::Remove(vec![undone_a]),
    )
    .await;
    submit(
        &store,
        channel,
        actor,
        CanvasOpRequest::Restore {
            target_op: remove_undone_a,
        },
    )
    .await;

    let undone_b = place(&store, channel, actor).await;
    let remove_undone_b = submit(
        &store,
        channel,
        actor,
        CanvasOpRequest::Remove(vec![undone_b]),
    )
    .await;
    submit(
        &store,
        channel,
        actor,
        CanvasOpRequest::Restore {
            target_op: remove_undone_b,
        },
    )
    .await;

    let still_dead = place(&store, channel, actor).await;
    submit(
        &store,
        channel,
        actor,
        CanvasOpRequest::Remove(vec![still_dead]),
    )
    .await;

    let untouched = place(&store, channel, actor).await;

    age_all_ops(&pool, AGE_DAYS).await;
    // Fresh activity after aging, so the sweep sees a mix in the same pass.
    let recent = place(&store, channel, actor).await;

    let swept = store.sweep_canvas_ops().await.unwrap();
    assert_eq!(swept.removes, 2, "the two fully-undone removes");
    assert_eq!(swept.restores, 2);
    assert_eq!(swept.clears, 0, "the live clear must survive");

    let replayed = replay_surviving_log(&store, channel).await;
    let live = live_objects(&pool, channel).await;
    assert_eq!(replayed, live);
    assert!(live.contains(&untouched));
    assert!(live.contains(&recent));
    assert!(!live.contains(&still_dead));
    assert!(!live.contains(&cleared_live));
    assert!(live.contains(&undone_a));
    assert!(live.contains(&undone_b));

    // A cold client from seq 0 sees no floor reset: place rows are never swept.
    let page = store.list_canvas_ops(channel, 0, 500).await.unwrap();
    assert!(!page.reset);
}

/// Replays whatever the surviving `canvas_ops` log says is alive, the same
/// reducer shape `canvas_ops/convergence.rs`'s own `replay_log` uses.
async fn replay_surviving_log(store: &Store, channel: ChannelId) -> HashSet<CanvasObjectId> {
    let mut placed: HashMap<CanvasObjectId, i64> = HashMap::new();
    let mut dead: HashSet<CanvasObjectId> = HashSet::new();
    let mut after = 0;
    loop {
        let page = store.list_canvas_ops(channel, after, 500).await.unwrap();
        assert!(!page.reset, "a swept-but-not-reset log must page cleanly");
        for op in &page.ops {
            match &op.body {
                CanvasOpBody::Place(Some(obj)) => {
                    placed.insert(obj.id, obj.seq.0);
                }
                CanvasOpBody::Place(None) => {}
                CanvasOpBody::Remove(ids) => dead.extend(ids.iter().copied()),
                CanvasOpBody::Clear { before_seq } => {
                    for (id, seq) in &placed {
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
                CanvasOpBody::Move { .. } | CanvasOpBody::Reorder { .. } => {}
            }
        }
        if page.has_more {
            after = page.ops.last().unwrap().seq;
        } else {
            break;
        }
    }
    placed.into_keys().filter(|id| !dead.contains(id)).collect()
}

async fn live_objects(pool: &SqlitePool, channel: ChannelId) -> HashSet<CanvasObjectId> {
    sqlx::query_scalar::<_, CanvasObjectId>(
        "SELECT id FROM canvas_objects WHERE channel_id = ? AND deleted_at IS NULL",
    )
    .bind(channel)
    .fetch_all(pool)
    .await
    .unwrap()
    .into_iter()
    .collect()
}
