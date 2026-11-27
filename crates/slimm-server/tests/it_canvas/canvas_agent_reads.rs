// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The reads an HTTP-only canvas client leans on: the op feed's long poll, one or several objects by id, and the board summary.

use std::time::{Duration, Instant};

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::Value;
use slimm_server::ids::{CanvasObjectId, ChannelId};
use slimm_server::permissions::Permissions;
use slimm_server::store::PlaceRequest;
use tower::ServiceExt;

use crate::canvas_ops::fixtures::{
    app, general, get_ops, id, member, new_store, post_object, register, remove, stroke, submit_op,
};

async fn get(app: &Router, uri: &str, token: &str) -> (StatusCode, Value) {
    let response = app
        .clone()
        .oneshot(
            Request::builder()
                .uri(uri)
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
    (
        status,
        serde_json::from_slice(&bytes).unwrap_or(Value::Null),
    )
}

fn objects_uri(channel: ChannelId, query: &str) -> String {
    format!("/channels/{channel}/canvas/objects?{query}")
}

fn object_uri(channel: ChannelId, object: &str) -> String {
    format!("/channels/{channel}/canvas/objects/{object}")
}

fn summary_uri(channel: ChannelId) -> String {
    format!("/channels/{channel}/canvas/summary")
}

fn box_at(object: &str, x: f64, y: f64, w: f64, h: f64) -> Value {
    let mut body = stroke(object);
    body["x"] = x.into();
    body["y"] = y.into();
    body["w"] = w.into();
    body["h"] = h.into();
    body
}

async fn place_box(
    app: &Router,
    channel: ChannelId,
    token: &str,
    at: (f64, f64, f64, f64),
) -> String {
    let object = id();
    let (status, body) =
        post_object(app, channel, token, box_at(&object, at.0, at.1, at.2, at.3)).await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
    object
}

// --- long poll ---

#[tokio::test]
async fn a_wait_with_nothing_new_answers_the_empty_page_after_the_wait() {
    let (store, _guard) = new_store().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store);

    let started = Instant::now();
    let (status, body) = get_ops(&app, channel, &token, "after_seq=0&wait=1").await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert!(
        started.elapsed() >= Duration::from_millis(900),
        "returned early"
    );
    assert_eq!(body["ops"], Value::Array(Vec::new()));
    assert_eq!(body["reset"], false);
}

#[tokio::test]
async fn a_waiting_read_wakes_on_the_next_op() {
    let (store, _guard) = new_store().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store);

    let waiter = {
        let (app, token) = (app.clone(), token.clone());
        tokio::spawn(async move { get_ops(&app, channel, &token, "after_seq=0&wait=20").await })
    };
    tokio::time::sleep(Duration::from_millis(300)).await;
    let started = Instant::now();
    let placed = place_box(&app, channel, &token, (0.0, 0.0, 10.0, 10.0)).await;
    let (status, body) = waiter.await.unwrap();

    assert_eq!(status, StatusCode::OK, "{body}");
    assert!(started.elapsed() < Duration::from_secs(5), "did not wake");
    assert_eq!(body["ops"][0]["object"]["id"], placed.as_str());
    assert_eq!(body["latest_seq"], 1);
}

#[tokio::test]
async fn a_waiting_read_wakes_on_a_removal() {
    let (store, _guard) = new_store().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store);
    let placed = place_box(&app, channel, &token, (0.0, 0.0, 10.0, 10.0)).await;

    let waiter = {
        let (app, token) = (app.clone(), token.clone());
        tokio::spawn(async move { get_ops(&app, channel, &token, "after_seq=1&wait=20").await })
    };
    tokio::time::sleep(Duration::from_millis(300)).await;
    let (status, _) = submit_op(&app, channel, &token, remove(&id(), &[&placed])).await;
    assert_eq!(status, StatusCode::CREATED);
    let (status, body) = waiter.await.unwrap();

    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["ops"][0]["kind"], "remove");
}

#[tokio::test]
async fn a_read_with_ops_waiting_answers_at_once() {
    let (store, _guard) = new_store().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store);
    place_box(&app, channel, &token, (0.0, 0.0, 10.0, 10.0)).await;

    let started = Instant::now();
    let (status, body) = get_ops(&app, channel, &token, "after_seq=0&wait=20").await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert!(
        started.elapsed() < Duration::from_secs(3),
        "waited with ops ready"
    );
    assert_eq!(body["ops"].as_array().unwrap().len(), 1);
}

#[tokio::test]
async fn a_reset_answers_at_once_instead_of_waiting() {
    let (store, _guard) = new_store().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store);

    let started = Instant::now();
    let (status, body) = get_ops(&app, channel, &token, "after_seq=99&wait=20").await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert!(
        started.elapsed() < Duration::from_secs(3),
        "waited on a reset"
    );
    assert_eq!(body["reset"], true);
}

#[tokio::test]
async fn another_boards_op_does_not_end_the_wait() {
    let (store, _guard) = new_store().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let other = store.create_channel("other", "canvas").await.unwrap().id;
    let app = app(store);

    let waiter = {
        let (app, token) = (app.clone(), token.clone());
        tokio::spawn(async move {
            let started = Instant::now();
            let answer = get_ops(&app, channel, &token, "after_seq=0&wait=2").await;
            (answer, started.elapsed())
        })
    };
    tokio::time::sleep(Duration::from_millis(300)).await;
    place_box(&app, other, &token, (0.0, 0.0, 10.0, 10.0)).await;
    let ((status, body), elapsed) = waiter.await.unwrap();

    assert_eq!(status, StatusCode::OK, "{body}");
    assert!(
        elapsed >= Duration::from_millis(1800),
        "woken by another board"
    );
    assert_eq!(body["ops"], Value::Array(Vec::new()));
}

#[tokio::test]
async fn one_user_may_hold_only_a_few_waits_at_once() {
    let (store, _guard) = new_store().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store);

    let mut held = Vec::new();
    for _ in 0..4 {
        let (app, token) = (app.clone(), token.clone());
        held.push(tokio::spawn(async move {
            get_ops(&app, channel, &token, "after_seq=0&wait=20").await
        }));
    }
    tokio::time::sleep(Duration::from_millis(400)).await;
    let (status, _) = get_ops(&app, channel, &token, "after_seq=0&wait=20").await;
    assert_eq!(status, StatusCode::TOO_MANY_REQUESTS);

    let (status, _) = get_ops(&app, channel, &token, "after_seq=0").await;
    assert_eq!(status, StatusCode::OK, "a plain read is never counted");
    place_box(&app, channel, &token, (0.0, 0.0, 10.0, 10.0)).await;
    for waiter in held {
        assert_eq!(waiter.await.unwrap().0, StatusCode::OK);
    }
    let (status, _) = get_ops(&app, channel, &token, "after_seq=0&wait=1").await;
    assert_eq!(status, StatusCode::OK, "released waits free their slots");
}

// --- objects by id ---

#[tokio::test]
async fn one_object_comes_back_in_the_viewport_shape() {
    let (store, _guard) = new_store().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store);
    let placed = place_box(&app, channel, &token, (5.0, 6.0, 7.0, 8.0)).await;

    let (status, body) = get(&app, &object_uri(channel, &placed), &token).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["id"], placed.as_str());
    assert_eq!(body["kind"], "stroke");
    assert_eq!(
        (body["x"].as_f64(), body["h"].as_f64()),
        (Some(5.0), Some(8.0))
    );
    assert!(body["props"]["points"].is_array());
    assert!(body["seq"].as_i64().unwrap() >= 1);
}

#[tokio::test]
async fn an_unknown_removed_or_foreign_object_is_not_found() {
    let (store, _guard) = new_store().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let other = store.create_channel("other", "canvas").await.unwrap().id;
    let app = app(store);
    let removed = place_box(&app, channel, &token, (0.0, 0.0, 10.0, 10.0)).await;
    let (status, _) = submit_op(&app, channel, &token, remove(&id(), &[&removed])).await;
    assert_eq!(status, StatusCode::CREATED);
    let foreign = place_box(&app, other, &token, (0.0, 0.0, 10.0, 10.0)).await;

    for object in [id(), removed, foreign] {
        let (status, body) = get(&app, &object_uri(channel, &object), &token).await;
        assert_eq!(status, StatusCode::NOT_FOUND, "{object}: {body}");
    }
    let (status, _) = get(&app, &object_uri(channel, "not-a-uuid"), &token).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn object_reads_follow_the_viewport_gate() {
    let (store, _guard) = new_store().await;
    store
        .create_role("everyone", Permissions::VIEW_CHANNEL, true)
        .await
        .unwrap();
    let (_, root) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());
    let placed = CanvasObjectId::generate();
    store
        .place_canvas_object(
            channel,
            root,
            placed,
            PlaceRequest {
                kind: "stroke",
                bounds: (0.0, 0.0, 10.0, 10.0),
                props: "{}",
                attachment: None,
            },
        )
        .await
        .unwrap();
    let placed = placed.to_string();

    let (spectator, _) = member(&store, "spectator").await;
    let (status, _) = get(&app, &object_uri(channel, &placed), &spectator).await;
    assert_eq!(status, StatusCode::OK, "viewing is enough");

    let (outsider, user) = member(&store, "outsider").await;
    store
        .set_member_overwrite(channel, user, Permissions::NONE, Permissions::VIEW_CHANNEL)
        .await
        .unwrap();
    for uri in [
        object_uri(channel, &placed),
        objects_uri(channel, &format!("ids={placed}")),
        summary_uri(channel),
    ] {
        let (status, _) = get(&app, &uri, &outsider).await;
        assert_eq!(status, StatusCode::FORBIDDEN, "{uri}");
    }
}

#[tokio::test]
async fn ids_return_those_live_objects_and_skip_the_rest() {
    let (store, _guard) = new_store().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let other = store.create_channel("other", "canvas").await.unwrap().id;
    let app = app(store);
    let first = place_box(&app, channel, &token, (0.0, 0.0, 10.0, 10.0)).await;
    let second = place_box(&app, channel, &token, (500.0, 500.0, 10.0, 10.0)).await;
    let _unasked = place_box(&app, channel, &token, (9.0, 9.0, 10.0, 10.0)).await;
    let gone = place_box(&app, channel, &token, (1.0, 1.0, 10.0, 10.0)).await;
    let (status, _) = submit_op(&app, channel, &token, remove(&id(), &[&gone])).await;
    assert_eq!(status, StatusCode::CREATED);
    let foreign = place_box(&app, other, &token, (0.0, 0.0, 10.0, 10.0)).await;

    let ids = format!("{first},{second},{gone},{foreign},{},{first}", id());
    let (status, body) = get(&app, &objects_uri(channel, &format!("ids={ids}")), &token).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    let found: Vec<&str> = body["objects"]
        .as_array()
        .unwrap()
        .iter()
        .map(|o| o["id"].as_str().unwrap())
        .collect();
    assert_eq!(found, vec![first.as_str(), second.as_str()]);
    assert_eq!(body["has_more"], false);
    assert_eq!(body["latest_seq"], 5);
}

#[tokio::test]
async fn ids_are_refused_when_malformed_too_many_or_mixed_with_a_rectangle() {
    let (store, _guard) = new_store().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store);
    let one = id();

    let many = (0..101).map(|_| id()).collect::<Vec<_>>().join(",");
    let at_cap = (0..100).map(|_| id()).collect::<Vec<_>>().join(",");
    let refused = [
        "ids=not-a-uuid".to_owned(),
        "ids=".to_owned(),
        format!("ids={many}"),
        format!("ids={one}&min_x=0&min_y=0&max_x=1&max_y=1"),
        format!("ids={one}&cursor_seq=0"),
        "min_x=0&min_y=0".to_owned(),
        String::new(),
    ];
    for query in refused {
        let (status, body) = get(&app, &objects_uri(channel, &query), &token).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{query:.80}: {body}");
    }
    let (status, body) = get(
        &app,
        &objects_uri(channel, &format!("ids={at_cap}")),
        &token,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["objects"], Value::Array(Vec::new()));
}

// --- summary ---

#[tokio::test]
async fn an_empty_board_summarises_to_no_bounds() {
    let (store, _guard) = new_store().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store);

    let (status, body) = get(&app, &summary_uri(channel), &token).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["count"], 0);
    assert_eq!(body["latest_seq"], 0);
    assert!(body["bounds"].is_null(), "{body}");
}

#[tokio::test]
async fn the_summary_counts_and_bounds_only_live_objects() {
    let (store, _guard) = new_store().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let other = store.create_channel("other", "canvas").await.unwrap().id;
    let app = app(store);
    place_box(&app, channel, &token, (-100.0, 20.0, 30.0, 40.0)).await;
    place_box(&app, channel, &token, (50.0, -70.0, 200.0, 10.0)).await;
    let far = place_box(&app, channel, &token, (3000.0, 4000.0, 5.0, 5.0)).await;
    place_box(&app, other, &token, (-9000.0, -9000.0, 1.0, 1.0)).await;

    let (_, body) = get(&app, &summary_uri(channel), &token).await;
    assert_eq!(body["count"], 3);
    assert_eq!(body["latest_seq"], 3);
    assert_eq!(body["bounds"]["min_x"], -100.0);
    assert_eq!(body["bounds"]["min_y"], -70.0);
    assert_eq!(body["bounds"]["max_x"], 3005.0);
    assert_eq!(body["bounds"]["max_y"], 4005.0);

    let (status, _) = submit_op(&app, channel, &token, remove(&id(), &[&far])).await;
    assert_eq!(status, StatusCode::CREATED);
    let (_, body) = get(&app, &summary_uri(channel), &token).await;
    assert_eq!(body["count"], 2);
    assert_eq!(body["latest_seq"], 4);
    assert_eq!(body["bounds"]["max_x"], 250.0);
    assert_eq!(body["bounds"]["max_y"], 60.0);
}

/// The summary reads the channel's live rows through the partial index, never the whole table.
#[tokio::test]
async fn the_summary_query_never_scans_the_object_table() {
    let (store, pool, _guard) = crate::canvas_ops::fixtures::new_store_and_pool().await;
    drop(store);
    let source = std::fs::read_to_string(
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/store/canvas/canvas_reads.rs"),
    )
    .unwrap();
    let start = source.find("COUNT(*)").expect("summary query");
    let open = source[..start].rfind("r#\"").unwrap() + 3;
    let close = source[start..].find("\"#").unwrap() + start;
    let sql = format!("EXPLAIN QUERY PLAN {}", &source[open..close]);
    let rows = sqlx::query(sqlx::AssertSqlSafe(sql))
        .bind(vec![0u8; 16])
        .fetch_all(&pool)
        .await
        .unwrap();
    let plan: Vec<String> = rows
        .iter()
        .map(|r| sqlx::Row::get::<String, _>(r, "detail"))
        .collect();
    assert!(
        plan.iter()
            .any(|s| s.contains("canvas_objects_channel_live")),
        "plan is {plan:?}"
    );
}
