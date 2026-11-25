// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Deleting a channel takes its canvas objects with it, and the image bytes they held.

use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ids::CanvasObjectId;
use slimm_server::store::{PlaceRequest, Store};

use crate::support;
use support::app::register_id as register;

#[tokio::test]
async fn deleting_a_channel_removes_its_canvas_objects_and_frees_their_image() {
    let (path, _guard) = support::TestDbGuard::new("slimm-canvas-deleted-channel");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    let store = Store::new(pool.clone());
    let actor = register(&store, "root").await;
    let doomed = store.create_channel("doomed", "canvas").await.unwrap().id;
    let sha = [0x24u8; 32];
    store
        .store_attachment(&sha, 8, "image/png", "p.png", Some(actor))
        .await
        .unwrap();
    for (kind, attachment) in [("image", Some(&sha[..])), ("stroke", None)] {
        store
            .place_canvas_object(
                doomed,
                actor,
                CanvasObjectId::generate(),
                PlaceRequest {
                    kind,
                    bounds: (0.0, 0.0, 1.0, 1.0),
                    props: "{}",
                    attachment,
                },
            )
            .await
            .expect("placed");
    }
    sqlx::query("UPDATE attachments SET created_at = created_at - 100000000")
        .execute(&pool)
        .await
        .unwrap();

    assert!(store.delete_channel(doomed).await.unwrap());
    store.sweep_canvas_ops().await.unwrap();

    let objects: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM canvas_objects WHERE channel_id = ?")
            .bind(doomed)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(objects, 0, "the deleted channel still holds canvas objects");
    assert_eq!(store.sweep_orphaned_attachments().await.unwrap().len(), 1);
}
