// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `POST /channels/{id}/canvas/ops/batch`: move, edit, remove and reorder many objects in one
//! transaction, each op with its own seq and event, all or nothing.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::hub::{CanvasEvent, Event, Hub};
use slimm_server::ids::{CanvasObjectId, ChannelId};
use tower::ServiceExt;
use uuid::Uuid;

use crate::canvas_ops::fixtures::{
    edit_op, general, get_ops, id, member, move_op, new_store, new_store_and_pool, note,
    post_object, register, remove, reorder_op, stroke,
};

async fn submit_batch(
    app: &Router,
    channel: ChannelId,
    token: &str,
    ops: Vec<Value>,
) -> (StatusCode, Value) {
    let response = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/channels/{channel}/canvas/ops/batch"))
                .header("authorization", format!("Bearer {token}"))
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::to_vec(&json!({ "ops": ops })).unwrap(),
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

async fn place(app: &Router, channel: ChannelId, token: &str, body: Value) -> String {
    let (status, placed) = post_object(app, channel, token, body).await;
    assert_eq!(status, StatusCode::CREATED, "{placed}");
    placed["id"].as_str().unwrap().to_owned()
}

async fn bounds(pool: &sqlx::SqlitePool, object_id: &str) -> (f64, f64, f64, f64) {
    sqlx::query_as("SELECT x, y, w, h FROM canvas_objects WHERE id = ?")
        .bind(Uuid::parse_str(object_id).unwrap())
        .fetch_one(pool)
        .await
        .unwrap()
}

async fn op_kinds(app: &Router, channel: ChannelId, token: &str) -> Vec<String> {
    let (_, ops) = get_ops(app, channel, token, "after_seq=0&limit=200").await;
    ops["ops"]
        .as_array()
        .unwrap()
        .iter()
        .map(|op| op["kind"].as_str().unwrap().to_owned())
        .collect()
}

fn drain(events: &mut tokio::sync::broadcast::Receiver<Event>) -> Vec<Event> {
    let mut seen = Vec::new();
    while let Ok(event) = events.try_recv() {
        seen.push(event);
    }
    seen
}

#[tokio::test]
async fn a_batch_of_moves_gives_each_op_its_own_seq_and_event() {
    let (store, pool, _guard) = new_store_and_pool().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let hub = Hub::new();
    let mut events = hub.subscribe();
    let app = crate::support::app::builder(store.clone())
        .hub(hub)
        .router();
    let mut objects = Vec::new();
    for _ in 0..3 {
        objects.push(place(&app, channel, &token, stroke(&id())).await);
    }
    drain(&mut events);

    let ops = objects
        .iter()
        .enumerate()
        .map(|(i, object)| move_op(&id(), object, (i as f64 * 100.0, 5.0, 50.0, 50.0)))
        .collect();
    let (status, body) = submit_batch(&app, channel, &token, ops).await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
    let results = body["ops"].as_array().unwrap();
    assert_eq!(results.len(), 3);
    let seqs: Vec<i64> = results
        .iter()
        .map(|r| r["op"]["seq"].as_i64().unwrap())
        .collect();
    assert!(seqs.windows(2).all(|w| w[1] == w[0] + 1), "{seqs:?}");
    assert!(results.iter().all(|r| r["fresh"] == true));
    for (i, object) in objects.iter().enumerate() {
        assert_eq!(
            bounds(&pool, object).await,
            (i as f64 * 100.0, 5.0, 50.0, 50.0)
        );
    }

    let moved: Vec<(i64, CanvasObjectId)> = drain(&mut events)
        .into_iter()
        .filter_map(|event| match event {
            Event::Canvas(CanvasEvent::ObjectMoved { seq, object_id, .. }) => {
                Some((seq.0, object_id))
            }
            _ => None,
        })
        .collect();
    assert_eq!(moved.iter().map(|m| m.0).collect::<Vec<_>>(), seqs);
    let ids: Vec<String> = moved.iter().map(|m| m.1.to_string()).collect();
    assert_eq!(ids, objects);
}

#[tokio::test]
async fn a_batch_may_mix_move_edit_reorder_and_remove() {
    let (store, pool, _guard) = new_store_and_pool().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = crate::support::app::router(store.clone());
    let a = place(&app, channel, &token, stroke(&id())).await;
    let b = place(&app, channel, &token, note(&id(), "old")).await;
    let c = place(&app, channel, &token, stroke(&id())).await;
    let d = place(&app, channel, &token, stroke(&id())).await;

    let (status, body) = submit_batch(
        &app,
        channel,
        &token,
        vec![
            move_op(&id(), &a, (1.0, 2.0, 3.0, 4.0)),
            edit_op(&id(), &b, json!({ "text": "new" })),
            reorder_op(&id(), &c, 99),
            remove(&id(), &[&d]),
        ],
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
    let kinds: Vec<&str> = body["ops"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| r["op"]["kind"].as_str().unwrap())
        .collect();
    assert_eq!(kinds, ["move", "edit", "reorder", "remove"]);
    assert_eq!(bounds(&pool, &a).await, (1.0, 2.0, 3.0, 4.0));
    let deleted: Option<i64> =
        sqlx::query_scalar("SELECT deleted_at FROM canvas_objects WHERE id = ?")
            .bind(Uuid::parse_str(&d).unwrap())
            .fetch_one(&pool)
            .await
            .unwrap();
    assert!(deleted.is_some());
}

#[tokio::test]
async fn one_refused_op_rolls_the_whole_batch_back_and_names_its_index() {
    let (store, pool, _guard) = new_store_and_pool().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let hub = Hub::new();
    let mut events = hub.subscribe();
    let app = crate::support::app::builder(store.clone())
        .hub(hub)
        .router();
    let a = place(&app, channel, &token, stroke(&id())).await;
    let b = place(&app, channel, &token, stroke(&id())).await;
    let before = bounds(&pool, &a).await;
    let ops_before = op_kinds(&app, channel, &token).await;
    drain(&mut events);

    let stranger = Uuid::now_v7().to_string();
    let (status, body) = submit_batch(
        &app,
        channel,
        &token,
        vec![
            move_op(&id(), &a, (500.0, 500.0, 5.0, 5.0)),
            remove(&id(), &[&b]),
            move_op(&id(), &stranger, (1.0, 1.0, 1.0, 1.0)),
        ],
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND, "{body}");
    assert_eq!(body["item_index"], 2);
    assert_eq!(body["item_code"], "not_found");
    assert_eq!(bounds(&pool, &a).await, before, "the first move is undone");
    assert_eq!(op_kinds(&app, channel, &token).await, ops_before);
    assert!(drain(&mut events).is_empty(), "nothing fans out");
}

#[tokio::test]
async fn a_refused_edit_or_lock_rolls_back_too() {
    let (store, _guard) = new_store().await;
    let (token, root_id) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = crate::support::app::router(store.clone());
    let a = place(&app, channel, &token, stroke(&id())).await;
    let pinned = place(&app, channel, &token, stroke(&id())).await;
    store
        .set_canvas_object_lock(
            channel,
            CanvasObjectId(Uuid::parse_str(&pinned).unwrap()),
            root_id,
            true,
            true,
        )
        .await
        .unwrap();
    let ops_before = op_kinds(&app, channel, &token).await;

    let (status, body) = submit_batch(
        &app,
        channel,
        &token,
        vec![
            move_op(&id(), &a, (9.0, 9.0, 9.0, 9.0)),
            move_op(&id(), &pinned, (9.0, 9.0, 9.0, 9.0)),
        ],
    )
    .await;
    assert_eq!(
        (status, &body["item_index"]),
        (StatusCode::CONFLICT, &json!(1)),
        "{body}"
    );

    let (status, body) = submit_batch(
        &app,
        channel,
        &token,
        vec![
            move_op(&id(), &a, (9.0, 9.0, 9.0, 9.0)),
            edit_op(&id(), &a, json!({ "text": "x" })),
        ],
    )
    .await;
    assert_eq!(
        (status, &body["item_index"]),
        (StatusCode::BAD_REQUEST, &json!(1)),
        "{body}"
    );
    assert_eq!(op_kinds(&app, channel, &token).await, ops_before);
}

#[tokio::test]
async fn a_retried_batch_answers_with_the_stored_ops_and_sends_nothing() {
    let (store, _guard) = new_store().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let hub = Hub::new();
    let mut events = hub.subscribe();
    let app = crate::support::app::builder(store.clone())
        .hub(hub)
        .router();
    let a = place(&app, channel, &token, stroke(&id())).await;
    let b = place(&app, channel, &token, stroke(&id())).await;
    let ops = vec![
        move_op(&id(), &a, (1.0, 1.0, 1.0, 1.0)),
        remove(&id(), &[&b]),
    ];
    let (_, first) = submit_batch(&app, channel, &token, ops.clone()).await;
    drain(&mut events);

    let (status, second) = submit_batch(&app, channel, &token, ops).await;
    assert_eq!(status, StatusCode::CREATED, "{second}");
    for (before, after) in first["ops"]
        .as_array()
        .unwrap()
        .iter()
        .zip(second["ops"].as_array().unwrap())
    {
        assert_eq!(before["op"], after["op"]);
        assert_eq!(after["fresh"], false);
    }
    assert!(drain(&mut events).is_empty());
}

#[tokio::test]
async fn a_batch_takes_only_the_four_kinds_and_distinct_ids() {
    let (store, _guard) = new_store().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = crate::support::app::router(store.clone());
    let a = place(&app, channel, &token, stroke(&id())).await;

    let (status, body) = submit_batch(
        &app,
        channel,
        &token,
        vec![
            move_op(&id(), &a, (1.0, 1.0, 1.0, 1.0)),
            json!({ "id": id(), "kind": "clear", "before_seq": 5 }),
        ],
    )
    .await;
    assert_eq!(
        (status, &body["item_index"]),
        (StatusCode::BAD_REQUEST, &json!(1)),
        "{body}"
    );

    let repeated = id();
    let (status, body) = submit_batch(
        &app,
        channel,
        &token,
        vec![
            move_op(&repeated, &a, (1.0, 1.0, 1.0, 1.0)),
            move_op(&repeated, &a, (2.0, 2.0, 2.0, 2.0)),
        ],
    )
    .await;
    assert_eq!(
        (status, &body["item_index"]),
        (StatusCode::BAD_REQUEST, &json!(1)),
        "{body}"
    );

    let (status, body) = submit_batch(
        &app,
        channel,
        &token,
        vec![json!({ "id": id(), "kind": "move", "object_id": a, "x": 1.0 })],
    )
    .await;
    assert_eq!(
        (status, &body["item_index"]),
        (StatusCode::BAD_REQUEST, &json!(0)),
        "{body}"
    );
}

#[tokio::test]
async fn a_batch_holds_one_to_two_hundred_ops() {
    let (store, _guard) = new_store().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = crate::support::app::router(store.clone());
    let a = place(&app, channel, &token, stroke(&id())).await;

    let (status, _) = submit_batch(&app, channel, &token, vec![]).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let too_many = (0..201)
        .map(|_| move_op(&id(), &a, (1.0, 1.0, 1.0, 1.0)))
        .collect();
    let (status, _) = submit_batch(&app, channel, &token, too_many).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let most = (0..200)
        .map(|i| move_op(&id(), &a, (f64::from(i), 1.0, 1.0, 1.0)))
        .collect();
    let (status, body) = submit_batch(&app, channel, &token, most).await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
}

#[tokio::test]
async fn a_member_may_not_move_anothers_object_in_a_batch() {
    let (store, _guard) = new_store().await;
    let (root, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = crate::support::app::router(store.clone());
    let (bob, _) = member(&store, "bob").await;
    let mine = place(&app, channel, &bob, stroke(&id())).await;
    let theirs = place(&app, channel, &root, stroke(&id())).await;

    let (status, body) = submit_batch(
        &app,
        channel,
        &bob,
        vec![
            move_op(&id(), &mine, (1.0, 1.0, 1.0, 1.0)),
            move_op(&id(), &theirs, (1.0, 1.0, 1.0, 1.0)),
        ],
    )
    .await;
    assert_eq!(
        (status, &body["item_index"]),
        (StatusCode::FORBIDDEN, &json!(1)),
        "{body}"
    );
}

#[tokio::test]
async fn a_timeout_freezes_a_batch_of_moves_but_not_a_batch_of_removes() {
    let (store, _guard) = new_store().await;
    let (_, root_id) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = crate::support::app::router(store.clone());
    let (bob, bob_id) = member(&store, "bob").await;
    let a = place(&app, channel, &bob, stroke(&id())).await;
    let b = place(&app, channel, &bob, stroke(&id())).await;
    let until = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
        + 60_000;
    store
        .set_member_timeout(bob_id, until, None, root_id)
        .await
        .unwrap();

    let (status, _) = submit_batch(
        &app,
        channel,
        &bob,
        vec![move_op(&id(), &a, (1.0, 1.0, 1.0, 1.0))],
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    let (status, body) = submit_batch(
        &app,
        channel,
        &bob,
        vec![remove(&id(), &[&a]), remove(&id(), &[&b])],
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
}
