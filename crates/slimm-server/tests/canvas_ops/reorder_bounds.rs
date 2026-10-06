// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
use axum::http::StatusCode;

use crate::fixtures::{
    app, general, id, member, new_store, post_object, register, reorder_op, stroke, submit_op,
};

#[tokio::test]
async fn control_a_normal_z_index_is_accepted() {
    let (store, _guard) = new_store().await;
    let (_t, _i) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());
    let (bob, _) = member(&store, "bob").await;
    let (_, placed) = post_object(&app, channel, &bob, stroke(&id())).await;
    let object_id = placed["id"].as_str().unwrap().to_owned();
    let (status, body) = submit_op(&app, channel, &bob, reorder_op(&id(), &object_id, 500)).await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
}

/// The documented range is inclusive at both ends.
#[tokio::test]
async fn the_documented_extremes_are_accepted() {
    let (store, _guard) = new_store().await;
    let (_t, _i) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());
    let (bob, _) = member(&store, "bob").await;
    let (_, placed) = post_object(&app, channel, &bob, stroke(&id())).await;
    let object_id = placed["id"].as_str().unwrap().to_owned();
    for z in [1_i64 << 52, -(1_i64 << 52)] {
        let (status, body) = submit_op(&app, channel, &bob, reorder_op(&id(), &object_id, z)).await;
        assert_eq!(status, StatusCode::CREATED, "z_index {z}: {body}");
    }
}

/// A z_index no client can step past without overflowing must be refused.
#[tokio::test]
async fn a_reorder_to_i64_max_is_refused() {
    let (store, _guard) = new_store().await;
    let (_t, _i) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());
    let (bob, _) = member(&store, "bob").await;
    let (_, placed) = post_object(&app, channel, &bob, stroke(&id())).await;
    let object_id = placed["id"].as_str().unwrap().to_owned();
    for z in [
        i64::MAX,
        i64::MIN,
        1_i64 << 53,
        (1_i64 << 52) + 1,
        -(1_i64 << 52) - 1,
    ] {
        let (status, body) = submit_op(&app, channel, &bob, reorder_op(&id(), &object_id, z)).await;
        assert_eq!(
            status,
            StatusCode::BAD_REQUEST,
            "z_index {z} answered {status}: {body}"
        );
    }
}
