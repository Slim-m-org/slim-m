// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! C-028: an erased object past retention is never reclaimed.

use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ids::{CanvasObjectId, CanvasOpId};
use slimm_server::store::{CanvasOpRequest, PlaceRequest, Store};

mod support;

use support::app::register_id as register;

const DAY_MS: i64 = 24 * 60 * 60 * 1000;

#[tokio::test]
async fn an_erased_object_past_retention_is_hard_deleted_by_the_sweep() {
    let (path, _guard) = support::TestDbGuard::new("slimm-canvas-erased-reclaim");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    let store = Store::new(pool.clone());
    let actor = register(&store, "root").await;
    let channel = store.list_channels().await.unwrap()[0].id;

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

    store.sweep_canvas_ops().await.unwrap();

    let rows: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM canvas_objects WHERE id = ?")
        .bind(object)
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(rows, 0, "an object erased a year ago is still stored");
}
