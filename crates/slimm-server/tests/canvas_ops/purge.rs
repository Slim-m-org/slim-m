// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Erased canvas content (decision 0085): a moderator purges an object for
//! good, and the sweep hard-deletes objects erased past message retention.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use slimm_server::ids::{CanvasObjectId, CanvasOpId, ChannelId, UserId};
use slimm_server::store::{CanvasOpRequest, PlaceRequest, Store};
use sqlx::SqlitePool;
use tower::ServiceExt;

use crate::fixtures::{app, general, member, new_store_and_pool, register};
use crate::support::canvas::{DAY_MS, age_canvas_history};

async fn place(store: &Store, channel: ChannelId, author: UserId, kind: &str) -> CanvasObjectId {
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

async fn erase(store: &Store, channel: ChannelId, actor: UserId, object: CanvasObjectId) {
    store
        .submit_canvas_op(
            channel,
            actor,
            CanvasOpId::generate(),
            true,
            CanvasOpRequest::Remove(vec![object]),
        )
        .await
        .expect("erased");
}

async fn count(pool: &SqlitePool, table: &str) -> i64 {
    sqlx::query_scalar(&format!("SELECT COUNT(*) FROM {table}"))
        .fetch_one(pool)
        .await
        .unwrap()
}

async fn delete(app: &Router, uri: &str, token: &str) -> StatusCode {
    let request = Request::builder()
        .method("DELETE")
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap();
    app.clone().oneshot(request).await.unwrap().status()
}

#[tokio::test]
async fn nothing_is_hard_deleted_while_retention_is_off() {
    let (store, pool, _guard) = new_store_and_pool().await;
    let (_, actor) = register(&store, "root").await;
    let channel = general(&store).await;
    let object = place(&store, channel, actor, "stroke").await;
    erase(&store, channel, actor, object).await;
    age_canvas_history(&pool, 400).await;

    store.sweep_canvas_ops().await.unwrap();

    assert_eq!(count(&pool, "canvas_objects").await, 1);
}

#[tokio::test]
async fn the_sweep_hard_deletes_what_was_erased_before_the_window_and_only_that() {
    let (store, pool, _guard) = new_store_and_pool().await;
    let (_, actor) = register(&store, "root").await;
    let channel = general(&store).await;
    store.set_message_retention_days(30).await.unwrap();
    let old = place(&store, channel, actor, "stroke").await;
    let kept_live = place(&store, channel, actor, "stroke").await;
    erase(&store, channel, actor, old).await;
    age_canvas_history(&pool, 40).await;
    let recent = place(&store, channel, actor, "stroke").await;
    erase(&store, channel, actor, recent).await;

    let swept = store.sweep_canvas_ops().await.unwrap();

    assert_eq!(swept.purged, 1);
    let left: Vec<CanvasObjectId> = sqlx::query_scalar("SELECT id FROM canvas_objects")
        .fetch_all(&pool)
        .await
        .unwrap();
    assert!(left.contains(&kept_live) && left.contains(&recent) && !left.contains(&old));
    let targets: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM canvas_op_targets WHERE object_id = ?")
            .bind(old)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(targets, 0, "the purged object keeps no op targets");
    let audit: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM canvas_audit_log WHERE object_id = ?")
            .bind(old)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(audit, 0, "the purged object keeps no audit rows");
}

#[tokio::test]
async fn a_purge_frees_the_image_bytes_for_the_attachment_sweep() {
    let (store, pool, _guard) = new_store_and_pool().await;
    let (_, actor) = register(&store, "root").await;
    let channel = general(&store).await;
    store.set_message_retention_days(30).await.unwrap();
    let sha = [0x42u8; 32];
    store
        .store_attachment(&sha, 8, "image/png", "p.png", Some(actor))
        .await
        .unwrap();
    let image = CanvasObjectId::generate();
    let request = PlaceRequest {
        kind: "image",
        bounds: (0.0, 0.0, 10.0, 10.0),
        props: "{}",
        attachment: Some(&sha),
    };
    store
        .place_canvas_object(channel, actor, image, request)
        .await
        .unwrap();
    erase(&store, channel, actor, image).await;
    age_canvas_history(&pool, 40).await;
    sqlx::query("UPDATE attachments SET created_at = created_at - ?")
        .bind(40 * DAY_MS)
        .execute(&pool)
        .await
        .unwrap();
    assert!(store.sweep_orphaned_attachments().await.unwrap().is_empty());

    store.sweep_canvas_ops().await.unwrap();

    assert_eq!(store.sweep_orphaned_attachments().await.unwrap().len(), 1);
    assert_eq!(count(&pool, "attachments").await, 0);
}

#[tokio::test]
async fn a_cursor_inside_purged_history_resets_but_a_fresh_one_does_not() {
    let (store, pool, _guard) = new_store_and_pool().await;
    let (_, actor) = register(&store, "root").await;
    let channel = general(&store).await;
    store.set_message_retention_days(30).await.unwrap();
    place(&store, channel, actor, "stroke").await;
    let old = place(&store, channel, actor, "stroke").await;
    erase(&store, channel, actor, old).await;
    age_canvas_history(&pool, 40).await;
    place(&store, channel, actor, "stroke").await;

    store.sweep_canvas_ops().await.unwrap();

    assert!(store.list_canvas_ops(channel, 1, 50).await.unwrap().reset);
    assert!(!store.list_canvas_ops(channel, 0, 50).await.unwrap().reset);
    assert!(!store.list_canvas_ops(channel, 3, 50).await.unwrap().reset);
}

#[tokio::test]
async fn a_moderator_purges_a_live_locked_object_and_a_member_cannot() {
    let (store, pool, _guard) = new_store_and_pool().await;
    let (admin, actor) = register(&store, "root").await;
    let (member_token, member_id) = member(&store, "bob").await;
    let channel = general(&store).await;
    let router = app(store.clone());
    let theirs = place(&store, channel, member_id, "image").await;
    store
        .set_canvas_object_lock(channel, theirs, actor, true, true)
        .await
        .unwrap();
    let uri = format!("/channels/{channel}/canvas/objects/{theirs}");

    assert_eq!(
        delete(&router, &uri, &member_token).await,
        StatusCode::FORBIDDEN
    );
    assert_eq!(count(&pool, "canvas_objects").await, 1);

    assert_eq!(delete(&router, &uri, &admin).await, StatusCode::NO_CONTENT);
    assert_eq!(count(&pool, "canvas_objects").await, 0);
    assert_eq!(delete(&router, &uri, &admin).await, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn a_purge_of_an_object_erased_earlier_removes_it_for_good() {
    let (store, pool, _guard) = new_store_and_pool().await;
    let (admin, actor) = register(&store, "root").await;
    let channel = general(&store).await;
    let router = app(store.clone());
    let object = place(&store, channel, actor, "stroke").await;
    erase(&store, channel, actor, object).await;

    let uri = format!("/channels/{channel}/canvas/objects/{object}");
    assert_eq!(delete(&router, &uri, &admin).await, StatusCode::NO_CONTENT);
    assert_eq!(count(&pool, "canvas_objects").await, 0);
}
