// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Locking a canvas object in place: who may, what a lock refuses, and that
//! an erase sweeping over a locked object leaves it while taking the rest.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::Value;
use slimm_server::ids::ChannelId;
use tower::ServiceExt;

use crate::fixtures::{
    app, general, id, member, move_op, new_store, post_object, register, remove, reorder_op,
    stroke, submit_op,
};

async fn send(app: &Router, method: &str, path: &str, token: &str) -> (StatusCode, Value) {
    let response = app
        .clone()
        .oneshot(
            Request::builder()
                .method(method)
                .uri(path)
                .header("authorization", format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let status = response.status();
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    let body = serde_json::from_slice(&bytes).unwrap_or(Value::Null);
    (status, body)
}

fn lock_path(channel: ChannelId, object_id: &str) -> String {
    format!("/channels/{channel}/canvas/objects/{object_id}/lock")
}

async fn locked_ids(app: &Router, channel: ChannelId, token: &str) -> Vec<String> {
    let (status, body) = send(
        app,
        "GET",
        &format!("/channels/{channel}/canvas/object-locks"),
        token,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    body["object_ids"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap().to_owned())
        .collect()
}

#[tokio::test]
async fn a_locked_object_refuses_a_move_and_a_reorder_until_unlocked() {
    let (store, _guard) = new_store().await;
    register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());
    let (bob, _) = member(&store, "bob").await;
    let (_, placed) = post_object(&app, channel, &bob, stroke(&id())).await;
    let object = placed["id"].as_str().unwrap().to_owned();

    let (status, _) = send(&app, "PUT", &lock_path(channel, &object), &bob).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert_eq!(locked_ids(&app, channel, &bob).await, vec![object.clone()]);

    let (status, body) = submit_op(
        &app,
        channel,
        &bob,
        move_op(&id(), &object, (10.0, 10.0, 5.0, 5.0)),
    )
    .await;
    assert_eq!(status, StatusCode::CONFLICT, "{body}");
    let (status, body) = submit_op(&app, channel, &bob, reorder_op(&id(), &object, 9)).await;
    assert_eq!(status, StatusCode::CONFLICT, "{body}");

    let (status, _) = send(&app, "DELETE", &lock_path(channel, &object), &bob).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert!(locked_ids(&app, channel, &bob).await.is_empty());
    let (status, body) = submit_op(
        &app,
        channel,
        &bob,
        move_op(&id(), &object, (10.0, 10.0, 5.0, 5.0)),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
}

#[tokio::test]
async fn an_erase_over_a_locked_object_takes_the_rest_and_leaves_it() {
    let (store, _guard) = new_store().await;
    register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());
    let (bob, _) = member(&store, "bob").await;
    let (_, image) = post_object(&app, channel, &bob, stroke(&id())).await;
    let (_, ink) = post_object(&app, channel, &bob, stroke(&id())).await;
    let image = image["id"].as_str().unwrap().to_owned();
    let ink = ink["id"].as_str().unwrap().to_owned();
    send(&app, "PUT", &lock_path(channel, &image), &bob).await;

    let (status, body) = submit_op(&app, channel, &bob, remove(&id(), &[&image, &ink])).await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
    assert_eq!(body["op"]["affected"], 1, "only the unlocked stroke goes");
    assert_eq!(locked_ids(&app, channel, &bob).await, vec![image]);
}

#[tokio::test]
async fn only_the_author_or_a_canvas_moderator_may_lock() {
    let (store, _guard) = new_store().await;
    let (root, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());
    let (bob, _) = member(&store, "bob").await;
    let (carol, _) = member(&store, "carol").await;
    let (_, placed) = post_object(&app, channel, &bob, stroke(&id())).await;
    let object = placed["id"].as_str().unwrap().to_owned();

    let (status, _) = send(&app, "PUT", &lock_path(channel, &object), &carol).await;
    assert_eq!(status, StatusCode::FORBIDDEN, "someone else's object");
    let (status, _) = send(&app, "PUT", &lock_path(channel, &object), &root).await;
    assert_eq!(
        status,
        StatusCode::NO_CONTENT,
        "the owner holds MANAGE_CANVAS"
    );

    let missing = uuid::Uuid::now_v7().to_string();
    let (status, _) = send(&app, "PUT", &lock_path(channel, &missing), &bob).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}
