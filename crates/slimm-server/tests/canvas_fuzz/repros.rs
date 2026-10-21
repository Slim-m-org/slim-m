// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Hand-built reproductions of what the randomized runs found.

use slimm_server::ids::{CanvasObjectId, CanvasOpId, ChannelId, UserId};
use slimm_server::store::{CanvasOpRequest, ClearScope, PlaceRequest, Store, SubmitOpError};
use sqlx::SqlitePool;

use crate::fixtures::{
    self, app, general, id, new_store_and_pool, post_object, register, remove, stroke, submit_op,
};
use crate::replay::{Client, first_diff};

const DAY_MS: i64 = 24 * 60 * 60 * 1000;

pub async fn place(
    store: &Store,
    channel: ChannelId,
    author: UserId,
    kind: &str,
) -> CanvasObjectId {
    let object = CanvasObjectId::generate();
    let request = PlaceRequest {
        kind,
        bounds: (0.0, 0.0, 10.0, 10.0),
        props: "{}",
        attachment: None,
    };
    store
        .place_canvas_object(channel, author, object, request)
        .await
        .expect("placed");
    object
}

pub async fn submit(
    store: &Store,
    channel: ChannelId,
    actor: UserId,
    request: CanvasOpRequest,
) -> Result<slimm_server::store::SubmittedOp, SubmitOpError> {
    store
        .submit_canvas_op(channel, actor, CanvasOpId::generate(), true, request)
        .await
}

async fn age_everything(pool: &SqlitePool) {
    sqlx::query("UPDATE canvas_ops SET created_at = created_at - ?")
        .bind(31 * DAY_MS)
        .execute(pool)
        .await
        .unwrap();
    sqlx::query(
        "UPDATE canvas_objects SET deleted_at = deleted_at - ? WHERE deleted_at IS NOT NULL",
    )
    .bind(31 * DAY_MS)
    .execute(pool)
    .await
    .unwrap();
}

pub async fn replay_matches_live(store: &Store, channel: ChannelId) -> Result<(), String> {
    let live = Client::cold(store, channel).await?.alive();
    let mut replayed = Client::default();
    replayed.catch_up(store, channel, 500, false).await?;
    first_diff("replay from 0", &replayed.alive(), &live).map_or(Ok(()), Err)
}

#[tokio::test]
async fn http_remove_naming_one_object_twice_is_not_a_server_error() {
    let (store, _guard) = fixtures::new_store().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let router = app(store.clone());
    let (_, placed) = post_object(&router, channel, &token, stroke(&id())).await;
    let object = placed["id"].as_str().unwrap().to_owned();

    let (status, body) =
        submit_op(&router, channel, &token, remove(&id(), &[&object, &object])).await;
    assert!(
        !status.is_server_error(),
        "a repeated id answered {status}: {body}"
    );
}

#[tokio::test]
async fn a_remove_naming_one_object_twice_leaves_the_stream_dense() {
    let (store, _pool, _guard) = new_store_and_pool().await;
    let (_, actor) = register(&store, "root").await;
    let channel = general(&store).await;
    let object = place(&store, channel, actor, "stroke").await;
    let _ = submit(
        &store,
        channel,
        actor,
        CanvasOpRequest::Remove(vec![object, object]),
    )
    .await;
    let next = place(&store, channel, actor, "stroke").await;
    let page = store.list_canvas_ops(channel, 0, 50).await.unwrap();
    let seqs: Vec<i64> = page.ops.iter().map(|op| op.seq).collect();
    assert!(
        seqs.windows(2).all(|w| w[1] == w[0] + 1),
        "gap after the failed remove: {seqs:?} (next object {next})"
    );
}

#[tokio::test]
async fn restoring_an_op_that_has_nothing_left_to_restore_is_not_a_cap_error() {
    let (store, _pool, _guard) = new_store_and_pool().await;
    let (_, actor) = register(&store, "root").await;
    let channel = general(&store).await;
    let mut objects = Vec::new();
    for _ in 0..120 {
        objects.push(place(&store, channel, actor, "stroke").await);
    }
    let erase = submit(
        &store,
        channel,
        actor,
        CanvasOpRequest::Remove(vec![objects[0]]),
    )
    .await
    .unwrap();
    submit(
        &store,
        channel,
        actor,
        CanvasOpRequest::Restore {
            target_op: erase.id,
        },
    )
    .await
    .unwrap();
    store.set_canvas_object_cap(100).await.unwrap();

    let again = submit(
        &store,
        channel,
        actor,
        CanvasOpRequest::Restore {
            target_op: erase.id,
        },
    )
    .await;
    assert!(
        matches!(again, Ok(ref op) if op.affected == 0),
        "an empty restore over the cap answered {:?}",
        again.map(|op| op.affected)
    );
}

#[tokio::test]
async fn a_replayed_edit_reports_what_the_original_did() {
    let (store, _pool, _guard) = new_store_and_pool().await;
    let (_, actor) = register(&store, "root").await;
    let channel = general(&store).await;
    let note = place(&store, channel, actor, "note").await;
    let edit = CanvasOpRequest::Edit {
        object_id: note,
        props: r#"{"text":"hello"}"#.to_owned(),
    };
    let op = CanvasOpId::generate();
    let first = store
        .submit_canvas_op(channel, actor, op, true, edit)
        .await
        .unwrap();
    let retry = CanvasOpRequest::Edit {
        object_id: note,
        props: r#"{"text":"hello"}"#.to_owned(),
    };
    let second = store
        .submit_canvas_op(channel, actor, op, true, retry)
        .await
        .unwrap();
    assert!(!second.fresh);
    assert_eq!(
        second.affected, first.affected,
        "the retry of an applied edit"
    );
}

#[tokio::test]
async fn a_replayed_clear_reports_what_the_original_did_even_after_an_undo() {
    let (store, _pool, _guard) = new_store_and_pool().await;
    let (_, actor) = register(&store, "root").await;
    let channel = general(&store).await;
    for _ in 0..3 {
        place(&store, channel, actor, "stroke").await;
    }
    let op = CanvasOpId::generate();
    let clear = || CanvasOpRequest::Clear {
        before_seq: 3,
        scope: ClearScope::default(),
    };
    let first = store
        .submit_canvas_op(channel, actor, op, true, clear())
        .await
        .unwrap();
    submit(
        &store,
        channel,
        actor,
        CanvasOpRequest::Restore { target_op: op },
    )
    .await
    .unwrap();
    let second = store
        .submit_canvas_op(channel, actor, op, true, clear())
        .await
        .unwrap();
    assert_eq!(
        second.affected, first.affected,
        "the retry of an applied clear after its undo"
    );
}

#[tokio::test]
async fn sweeping_a_remove_and_its_restore_does_not_change_what_a_later_clear_replays_to() {
    let (store, pool, _guard) = new_store_and_pool().await;
    let (_, actor) = register(&store, "root").await;
    let channel = general(&store).await;
    let kept = place(&store, channel, actor, "stroke").await;
    let victim = place(&store, channel, actor, "stroke").await;
    let erase = submit(&store, channel, actor, CanvasOpRequest::Remove(vec![kept]))
        .await
        .unwrap();
    let head = store
        .list_canvas_ops(channel, 0, 1)
        .await
        .unwrap()
        .latest_seq;
    submit(
        &store,
        channel,
        actor,
        CanvasOpRequest::Clear {
            before_seq: head,
            scope: ClearScope::default(),
        },
    )
    .await
    .unwrap();
    submit(
        &store,
        channel,
        actor,
        CanvasOpRequest::Restore {
            target_op: erase.id,
        },
    )
    .await
    .unwrap();
    assert!(
        Client::cold(&store, channel)
            .await
            .unwrap()
            .alive()
            .contains_key(&kept),
        "the restore brought {kept} back ({victim} stays cleared)"
    );
    replay_matches_live(&store, channel)
        .await
        .expect("before the sweep");

    age_everything(&pool).await;
    store.sweep_canvas_ops().await.unwrap();
    replay_matches_live(&store, channel)
        .await
        .expect("after the sweep");
}

#[tokio::test]
async fn a_large_backlog_of_undone_erases_sweeps_to_a_feed_that_still_replays() {
    let (store, pool, _guard) = new_store_and_pool().await;
    let (_, actor) = register(&store, "root").await;
    let channel = general(&store).await;
    for _ in 0..620 {
        let object = place(&store, channel, actor, "stroke").await;
        let erase = submit(
            &store,
            channel,
            actor,
            CanvasOpRequest::Remove(vec![object]),
        )
        .await
        .unwrap();
        submit(
            &store,
            channel,
            actor,
            CanvasOpRequest::Restore {
                target_op: erase.id,
            },
        )
        .await
        .unwrap();
    }
    age_everything(&pool).await;
    for pass in 0..3 {
        store.sweep_canvas_ops().await.unwrap();
        replay_matches_live(&store, channel)
            .await
            .unwrap_or_else(|e| panic!("after sweep pass {pass}: {e}"));
    }
}

#[tokio::test]
async fn erased_objects_do_not_accumulate_forever() {
    let (store, pool, _guard) = new_store_and_pool().await;
    let (_, actor) = register(&store, "root").await;
    let channel = general(&store).await;
    store.set_canvas_object_cap(100).await.unwrap();
    for _ in 0..4 {
        let mut batch = Vec::new();
        for _ in 0..50 {
            batch.push(place(&store, channel, actor, "stroke").await);
        }
        submit(&store, channel, actor, CanvasOpRequest::Remove(batch))
            .await
            .unwrap();
    }
    age_everything(&pool).await;
    store.sweep_canvas_ops().await.unwrap();
    let kept: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM canvas_objects")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(kept, 200, "nothing is deleted while retention is off");
    store.set_message_retention_days(30).await.unwrap();
    store.sweep_canvas_ops().await.unwrap();

    let rows: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM canvas_objects")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert!(
        rows < 200,
        "{rows} erased objects are still stored a month after they were erased"
    );
}

#[tokio::test]
async fn the_viewport_read_finds_an_object_that_ends_at_a_tiny_coordinate() {
    use slimm_server::store::{Rect, ViewportQuery};
    let (store, _pool, _guard) = new_store_and_pool().await;
    let (_, actor) = register(&store, "root").await;
    let channel = general(&store).await;
    let object = CanvasObjectId::generate();
    let request = PlaceRequest {
        kind: "stroke",
        bounds: (0.0, 0.0, f64::MIN_POSITIVE, 1.0),
        props: "{}",
        attachment: None,
    };
    store
        .place_canvas_object(channel, actor, object, request)
        .await
        .unwrap();
    let query = ViewportQuery {
        view: Rect {
            min_x: f64::MIN_POSITIVE,
            min_y: -1.0,
            max_x: 5.0,
            max_y: 5.0,
        },
        previous: None,
        after_seq: 0,
        limit: 10,
    };
    let (_, found) = store.viewport_snapshot(channel, &query).await.unwrap();
    assert_eq!(
        found.len(),
        1,
        "an object whose far edge touches the window"
    );
}

#[tokio::test]
async fn a_clear_leaves_a_locked_object_in_place() {
    let (store, _pool, _guard) = new_store_and_pool().await;
    let (_, actor) = register(&store, "root").await;
    let channel = general(&store).await;
    let pinned = place(&store, channel, actor, "image").await;
    let ink = place(&store, channel, actor, "stroke").await;
    store
        .set_canvas_object_lock(channel, pinned, actor, true, true)
        .await
        .unwrap();
    let head = store
        .list_canvas_ops(channel, 0, 1)
        .await
        .unwrap()
        .latest_seq;
    submit(
        &store,
        channel,
        actor,
        CanvasOpRequest::Clear {
            before_seq: head,
            scope: ClearScope::default(),
        },
    )
    .await
    .unwrap();
    let alive = Client::cold(&store, channel).await.unwrap().alive();
    assert!(!alive.contains_key(&ink));
    assert!(alive.contains_key(&pinned), "the locked object was cleared");
}
