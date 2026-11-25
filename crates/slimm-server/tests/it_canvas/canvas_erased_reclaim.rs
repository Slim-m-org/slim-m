// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! An erased object past retention is never reclaimed.

use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ids::{CanvasObjectId, CanvasOpId};
use slimm_server::store::{CanvasOpRequest, PlaceRequest, Store};

use crate::support;
use support::app::register_id as register;

const DAY_MS: i64 = 24 * 60 * 60 * 1000;

async fn erased_a_year_ago() -> (
    Store,
    sqlx::SqlitePool,
    CanvasObjectId,
    support::TestDbGuard,
) {
    let (path, guard) = support::TestDbGuard::new("slimm-canvas-erased-reclaim");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    let store = Store::new(pool.clone());
    let actor = register(&store, "root").await;
    let channel = store.create_channel("board", "canvas").await.unwrap().id;

    let object = CanvasObjectId::generate();
    store
        .place_canvas_object(
            channel,
            actor,
            object,
            PlaceRequest {
                kind: "stroke",
                bounds: (0.0, 0.0, 1.0, 1.0),
                props: "{}",
                attachment: None,
            },
        )
        .await
        .expect("placed");
    store
        .submit_canvas_op(
            channel,
            actor,
            CanvasOpId::generate(),
            true,
            CanvasOpRequest::Remove(vec![object]),
        )
        .await
        .expect("removed");

    let delta = 365 * DAY_MS;
    sqlx::query("UPDATE canvas_ops SET created_at = created_at - ?")
        .bind(delta)
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query(
        "UPDATE canvas_objects SET deleted_at = deleted_at - ? WHERE deleted_at IS NOT NULL",
    )
    .bind(delta)
    .execute(&pool)
    .await
    .unwrap();

    store.set_message_retention_days(30).await.unwrap();
    (store, pool, object, guard)
}

async fn stored(pool: &sqlx::SqlitePool, object: CanvasObjectId) -> i64 {
    sqlx::query_scalar("SELECT COUNT(*) FROM canvas_objects WHERE id = ?")
        .bind(object)
        .fetch_one(pool)
        .await
        .unwrap()
}

#[tokio::test]
async fn an_erased_object_past_retention_is_hard_deleted_by_the_sweep() {
    let (store, pool, object, _guard) = erased_a_year_ago().await;
    store.sweep_canvas_ops().await.unwrap();

    let rows = stored(&pool, object).await;
    assert_eq!(rows, 0, "an object erased a year ago is still stored");
}

#[tokio::test]
async fn a_failing_audit_sweep_does_not_stop_the_erased_object_purge() {
    let (store, pool, object, _guard) = erased_a_year_ago().await;
    let other = register(&store, "other").await;
    let channel = store.create_channel("board", "canvas").await.unwrap().id;
    store
        .place_canvas_object(
            channel,
            other,
            CanvasObjectId::generate(),
            PlaceRequest {
                kind: "stroke",
                bounds: (0.0, 0.0, 1.0, 1.0),
                props: "{}",
                attachment: None,
            },
        )
        .await
        .expect("placed");
    sqlx::query(
        "INSERT INTO canvas_audit_log (channel_id, object_id, actor_id, action, created_at)
         SELECT channel_id, id, NULL, 'remove', 0 FROM canvas_objects WHERE deleted_at IS NULL",
    )
    .execute(&pool)
    .await
    .unwrap();
    sqlx::query(
        "CREATE TRIGGER refuse_live_audit_delete BEFORE DELETE ON canvas_audit_log
         WHEN (SELECT deleted_at FROM canvas_objects WHERE id = OLD.object_id) IS NULL
         BEGIN SELECT RAISE(ABORT, 'refused'); END",
    )
    .execute(&pool)
    .await
    .unwrap();

    let swept = store.sweep_canvas_ops().await;

    assert!(swept.is_ok(), "{swept:?}");
    assert_eq!(stored(&pool, object).await, 0, "the purge was skipped");
}
