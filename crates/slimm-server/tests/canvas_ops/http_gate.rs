// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The route wired end to end: gating, query validation, and a real
//! placement over HTTP reaching the feed over HTTP.

use axum::http::StatusCode;
use slimm_server::permissions::Permissions;

use crate::fixtures::{app, general, get_ops, id, post_object, register, stroke};

/// Seeing a channel is not seeing its canvas ops, exactly as the viewport
/// read already requires: `VIEW_CHANNEL` alone must not be enough.
#[tokio::test]
async fn reading_the_ops_feed_needs_the_canvas_bit_as_well_as_the_view_bit() {
    let (store, _guard) = crate::fixtures::new_store().await;
    store
        .create_role("everyone", Permissions::VIEW_CHANNEL, true)
        .await
        .unwrap();
    let drawers = store
        .create_role("drawers", Permissions::USE_CANVAS, false)
        .await
        .unwrap();
    let app = app(store.clone());
    let channel = store.create_channel("canvas", "voice").await.unwrap().id;

    let (token, user) = register(&store, "ann").await;
    let (status, body) = get_ops(&app, channel, &token, "after_seq=0").await;
    assert_eq!(status, StatusCode::FORBIDDEN, "{body}");

    store.assign_role(user, drawers).await.unwrap();
    let (status, body) = get_ops(&app, channel, &token, "after_seq=0").await;
    assert_eq!(status, StatusCode::OK, "{body}");
}

#[tokio::test]
async fn a_negative_after_seq_is_refused() {
    let (store, _guard) = crate::fixtures::new_store().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;

    let (status, body) = get_ops(&app(store), channel, &token, "after_seq=-1").await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "{body}");
}

/// The end-to-end path: a real HTTP placement writes an op the feed then
/// pages back, over the real route rather than the store method directly.
#[tokio::test]
async fn the_feed_is_dense_over_place_ops_placed_over_http() {
    let (store, _guard) = crate::fixtures::new_store().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());

    for _ in 0..5 {
        let (status, _) = post_object(&app, channel, &token, stroke(&id())).await;
        assert_eq!(status, StatusCode::CREATED);
    }

    let (status, body) = get_ops(&app, channel, &token, "after_seq=0").await;
    assert_eq!(status, StatusCode::OK, "{body}");
    let ops = body["ops"].as_array().unwrap();
    assert_eq!(ops.len(), 5);
    let seqs: Vec<i64> = ops.iter().map(|o| o["seq"].as_i64().unwrap()).collect();
    assert_eq!(
        seqs,
        vec![1, 2, 3, 4, 5],
        "the sequence must be dense with no gap"
    );
    assert!(ops.iter().all(|o| o["kind"] == "place"));
    assert_eq!(body["latest_seq"], 5);
    assert_eq!(body["has_more"], false);
    assert_eq!(body["reset"], false);
}

/// A moderation act must not name its moderator to the whole channel.
///
/// [`CanvasEvent::ObjectsRemoved`] withholds the actor deliberately, and this
/// feed handed the same channel exactly what that withholds - more reliably,
/// since a live frame is ephemeral and this read is durable and repeatable.
/// A `place` keeps its actor because `CanvasObject.author_id` is already on
/// the viewport read, so hiding it here would hide nothing.
#[tokio::test]
async fn the_feed_names_who_drew_but_not_who_removed() {
    let (store, _guard) = crate::fixtures::new_store().await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::USE_CANVAS),
            true,
        )
        .await
        .unwrap();
    let mods = store
        .create_role("mods", Permissions::MANAGE_CANVAS, false)
        .await
        .unwrap();
    let (root, root_id) = register(&store, "root").await;
    store.assign_role(root_id, mods).await.unwrap();
    let (bystander, _) = crate::fixtures::member(&store, "bystander").await;
    let channel = store.create_channel("canvas", "voice").await.unwrap().id;
    let app = app(store.clone());

    let object = id();
    let (status, _) = post_object(&app, channel, &root, stroke(&object)).await;
    assert_eq!(status, StatusCode::CREATED);
    let (status, _) = crate::fixtures::submit_op(
        &app,
        channel,
        &root,
        crate::fixtures::remove(&id(), &[&object]),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED);

    let (status, body) = get_ops(&app, channel, &bystander, "after_seq=0").await;
    assert_eq!(status, StatusCode::OK, "{body}");
    let ops = body["ops"].as_array().unwrap();
    assert_eq!(ops.len(), 2);
    assert_eq!(ops[0]["kind"], "place");
    assert!(
        ops[0]["actor_id"].is_string(),
        "who drew is already public on the viewport read"
    );
    assert_eq!(ops[1]["kind"], "remove");
    assert!(
        ops[1]["actor_id"].is_null(),
        "who removed must not be readable by the whole channel: {body}"
    );

    let (status, body) = get_ops(&app, channel, &root, "after_seq=0").await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert!(
        body["ops"][1]["actor_id"].is_string(),
        "a moderator keeps the trail, which is why the ops table is not compacted"
    );
}
