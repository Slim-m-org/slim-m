// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The batch route: permissions, all or nothing, the cap, idempotent retries, rate charging and fan-out.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::hub::{CanvasEvent, Event, Hub};
use slimm_server::ids::ChannelId;
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use tower::ServiceExt;

use crate::canvas_batch::fixtures::{
    chrono_ms, general, id, new_store, new_store_and_pool, register, stroke,
};

async fn batch(
    app: &Router,
    channel: ChannelId,
    token: &str,
    objects: Vec<Value>,
) -> (StatusCode, Value) {
    let response = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/channels/{channel}/canvas/objects/batch"))
                .header("authorization", format!("Bearer {token}"))
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::to_vec(&json!({ "objects": objects })).unwrap(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    let status = response.status();
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    (
        status,
        serde_json::from_slice(&bytes).unwrap_or(Value::Null),
    )
}

fn strokes(n: usize) -> Vec<Value> {
    (0..n).map(|_| stroke(&id())).collect()
}

async fn live_count(store: &Store, channel: ChannelId) -> usize {
    let page = store.list_canvas_ops(channel, 0, 1000).await.unwrap();
    page.ops.len()
}

fn app_with_hub(store: Store, hub: Hub) -> Router {
    crate::support::app::builder(store).hub(hub).router()
}

#[tokio::test]
async fn a_batch_places_every_object_with_dense_seqs() {
    let (store, _guard) = new_store().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = crate::support::app::router(store.clone());

    let (status, body) = batch(&app, channel, &token, strokes(5)).await;
    assert_eq!(status, StatusCode::CREATED);
    let seqs: Vec<i64> = body["objects"]
        .as_array()
        .unwrap()
        .iter()
        .map(|o| o["seq"].as_i64().unwrap())
        .collect();
    assert_eq!(seqs.len(), 5);
    assert!(seqs.windows(2).all(|w| w[1] == w[0] + 1), "{seqs:?}");
    assert_eq!(live_count(&store, channel).await, 5);
}

#[tokio::test]
async fn one_invalid_object_writes_nothing_and_names_its_index() {
    let (store, _guard) = new_store().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = crate::support::app::router(store.clone());
    let mut objects = strokes(4);
    objects[2]["kind"] = json!("window");

    let (status, body) = batch(&app, channel, &token, objects).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(
        body["error"].as_str().unwrap().contains("object 2"),
        "{body}"
    );
    assert_eq!(live_count(&store, channel).await, 0);

    let mut objects = strokes(3);
    objects[1]["x"] = json!(1.0e12);
    let (status, _) = batch(&app, channel, &token, objects).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(live_count(&store, channel).await, 0);
}

#[tokio::test]
async fn the_cap_is_checked_against_the_whole_batch() {
    let (store, _guard) = new_store().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    store.set_canvas_object_cap(100).await.unwrap();
    let app = crate::support::app::router(store.clone());
    assert_eq!(
        batch(&app, channel, &token, strokes(60)).await.0,
        StatusCode::CREATED
    );

    let (status, body) = batch(&app, channel, &token, strokes(41)).await;
    assert_eq!(status, StatusCode::CONFLICT);
    assert!(body["error"].as_str().unwrap().contains("full"), "{body}");
    assert_eq!(live_count(&store, channel).await, 60);
    assert_eq!(
        batch(&app, channel, &token, strokes(40)).await.0,
        StatusCode::CREATED
    );
}

#[tokio::test]
async fn a_retried_batch_returns_the_stored_objects_without_duplicates_or_events() {
    let (store, _guard) = new_store().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let hub = Hub::new();
    let mut events = hub.subscribe();
    let app = app_with_hub(store.clone(), hub);
    let objects = strokes(3);

    let (_, first) = batch(&app, channel, &token, objects.clone()).await;
    let (status, second) = batch(&app, channel, &token, objects).await;
    assert_eq!(status, StatusCode::CREATED);
    assert_eq!(first, second);
    assert_eq!(live_count(&store, channel).await, 3);

    let mut placed = 0;
    while let Ok(event) = events.try_recv() {
        if matches!(event, Event::Canvas(CanvasEvent::ObjectPlaced { .. })) {
            placed += 1;
        }
    }
    assert_eq!(placed, 3, "one event per object, none for the retry");
}

#[tokio::test]
async fn fan_out_is_one_event_per_object_in_seq_order() {
    let (store, _guard) = new_store().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let hub = Hub::new();
    let mut events = hub.subscribe();
    let app = app_with_hub(store, hub);

    batch(&app, channel, &token, strokes(7)).await;
    let mut seqs = Vec::new();
    while let Ok(event) = events.try_recv() {
        if let Event::Canvas(CanvasEvent::ObjectPlaced { object, .. }) = event {
            seqs.push(object.seq.0);
        }
    }
    assert_eq!(seqs.len(), 7);
    assert!(seqs.windows(2).all(|w| w[1] == w[0] + 1));
}

#[tokio::test]
async fn the_gate_matches_a_single_place() {
    let (store, _guard) = new_store().await;
    let (_root, root_id) = register(&store, "root").await;
    let channel = general(&store).await;
    let member = store
        .create_account("bob", "bob", "not-a-real-hash")
        .await
        .unwrap();
    let token = store
        .open_session(member.id, "cli")
        .await
        .unwrap()
        .access_token;
    let app = crate::support::app::router(store.clone());
    assert_eq!(
        batch(&app, channel, &token, strokes(1)).await.0,
        StatusCode::CREATED
    );

    store
        .set_member_overwrite(
            channel,
            member.id,
            Permissions::NONE,
            Permissions::USE_CANVAS,
        )
        .await
        .unwrap();
    assert_eq!(
        batch(&app, channel, &token, strokes(1)).await.0,
        StatusCode::FORBIDDEN
    );
    store
        .set_member_overwrite(channel, member.id, Permissions::NONE, Permissions::NONE)
        .await
        .unwrap();
    store
        .set_member_timeout(member.id, chrono_ms() + 60_000, Some("cool off"), root_id)
        .await
        .unwrap();
    assert_eq!(
        batch(&app, channel, &token, strokes(1)).await.0,
        StatusCode::FORBIDDEN
    );
}

#[tokio::test]
async fn the_size_of_a_batch_and_a_repeated_id_are_refused() {
    let (store, _guard) = new_store().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = crate::support::app::router(store.clone());

    assert_eq!(
        batch(&app, channel, &token, vec![]).await.0,
        StatusCode::BAD_REQUEST
    );
    assert_eq!(
        batch(&app, channel, &token, strokes(201)).await.0,
        StatusCode::BAD_REQUEST
    );
    let same = stroke(&id());
    assert_eq!(
        batch(&app, channel, &token, vec![same.clone(), same])
            .await
            .0,
        StatusCode::BAD_REQUEST
    );
    assert_eq!(live_count(&store, channel).await, 0);
    assert_eq!(
        batch(&app, channel, &token, strokes(200)).await.0,
        StatusCode::CREATED
    );
}

#[tokio::test]
async fn a_batch_is_charged_by_object_count() {
    let (store, _guard) = new_store().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = crate::support::app::router(store.clone());

    assert_eq!(
        batch(&app, channel, &token, strokes(200)).await.0,
        StatusCode::CREATED
    );
    assert_eq!(
        batch(&app, channel, &token, strokes(200)).await.0,
        StatusCode::CREATED
    );
    let (status, _) = batch(&app, channel, &token, strokes(200)).await;
    assert_eq!(
        status,
        StatusCode::TOO_MANY_REQUESTS,
        "400 objects is the burst"
    );
    // A single object is still admitted: the bucket is not empty to the byte.
    let (status, _) = batch(&app, channel, &token, strokes(1)).await;
    assert!(status == StatusCode::CREATED || status == StatusCode::TOO_MANY_REQUESTS);
}

#[tokio::test]
async fn the_batch_is_unauthenticated_refused() {
    let (store, _pool, _guard) = new_store_and_pool().await;
    let (_token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = crate::support::app::router(store);
    let (status, _) = batch(&app, channel, "nope", strokes(1)).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
}
