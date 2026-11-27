// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `kind: "edit"` on a shape and an image: display props merge over what is stored, and an
//! image keeps the attachment it was placed with.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::hub::{CanvasEvent, Event, Hub};
use tower::ServiceExt;
use uuid::Uuid;

use crate::canvas_ops::fixtures::{
    edit_op, general, id, new_store_and_pool, post_object, register, submit_op,
};

const PNG: [u8; 8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

async fn upload(app: &Router, token: &str, name: &str) -> String {
    let mut bytes = PNG.to_vec();
    bytes.extend_from_slice(name.as_bytes());
    let response = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/attachments?filename={name}.png"))
                .header("authorization", format!("Bearer {token}"))
                .body(Body::from(bytes))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::CREATED);
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    let body: Value = serde_json::from_slice(&bytes).unwrap();
    body["id"].as_str().unwrap().to_owned()
}

async fn props_of(pool: &sqlx::SqlitePool, object_id: &str) -> Value {
    let raw: String =
        sqlx::query_scalar("SELECT props FROM canvas_object_props WHERE object_id = ?")
            .bind(Uuid::parse_str(object_id).unwrap())
            .fetch_one(pool)
            .await
            .unwrap();
    serde_json::from_str(&raw).unwrap()
}

fn shape(id: &str) -> Value {
    json!({
        "id": id, "kind": "shape", "x": 0.0, "y": 0.0, "w": 80.0, "h": 40.0,
        "props": { "shape": "rectangle", "color": "red", "label": "a" },
    })
}

fn image(id: &str, attachment: &str) -> Value {
    json!({
        "id": id, "kind": "image", "x": 0.0, "y": 0.0, "w": 64.0, "h": 64.0,
        "props": { "attachment": attachment, "caption": "first" },
    })
}

#[tokio::test]
async fn a_shape_edit_merges_and_tells_viewers_the_merged_props() {
    let (store, pool, _guard) = new_store_and_pool().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let hub = Hub::new();
    let mut events = hub.subscribe();
    let app = crate::support::app::builder(store).hub(hub).router();
    let (_, placed) = post_object(&app, channel, &token, shape(&id())).await;
    let object = placed["id"].as_str().unwrap().to_owned();

    let (status, body) = submit_op(
        &app,
        channel,
        &token,
        edit_op(
            &id(),
            &object,
            json!({ "color": "blue", "label": null, "flip_x": true }),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
    assert_eq!(body["op"]["affected"], 1);
    let merged = json!({ "shape": "rectangle", "color": "blue", "flip_x": true });
    assert_eq!(props_of(&pool, &object).await, merged);

    let mut edited = None;
    while let Ok(event) = events.try_recv() {
        if let Event::Canvas(CanvasEvent::ObjectEdited { props, .. }) = event {
            edited = Some(props);
        }
    }
    let edited: Value = serde_json::from_str(&edited.expect("an edited event")).unwrap();
    assert_eq!(edited, merged);
}

#[tokio::test]
async fn an_image_caption_can_change_but_never_its_attachment() {
    let (store, pool, _guard) = new_store_and_pool().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = crate::support::app::router(store);
    let first = upload(&app, &token, "one").await;
    let second = upload(&app, &token, "two").await;
    let (status, placed) = post_object(&app, channel, &token, image(&id(), &first)).await;
    assert_eq!(status, StatusCode::CREATED, "{placed}");
    let object = placed["id"].as_str().unwrap().to_owned();

    let (status, body) = submit_op(
        &app,
        channel,
        &token,
        edit_op(
            &id(),
            &object,
            json!({ "caption": "second", "attachment": first }),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
    assert_eq!(props_of(&pool, &object).await["caption"], "second");

    for bad in [
        json!({ "attachment": second }),
        json!({ "attachment": null }),
    ] {
        let (status, body) = submit_op(&app, channel, &token, edit_op(&id(), &object, bad)).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{body}");
    }
    assert_eq!(props_of(&pool, &object).await["attachment"], first);
}

#[tokio::test]
async fn a_shape_edit_over_the_props_limit_is_refused() {
    let (store, _pool, _guard) = new_store_and_pool().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = crate::support::app::router(store);
    let (_, placed) = post_object(&app, channel, &token, shape(&id())).await;
    let object = placed["id"].as_str().unwrap().to_owned();
    let (status, body) = submit_op(
        &app,
        channel,
        &token,
        edit_op(&id(), &object, json!({ "label": "x".repeat(5000) })),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "{body}");
}
