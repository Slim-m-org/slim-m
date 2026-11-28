// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The canvas API holds every write to the board (decision 0080): a place, a move and a free edge
//! end that would leave it are refused, and old content outside it can still be brought in.

use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::ids::CanvasObjectId;
use tower::ServiceExt;
use uuid::Uuid;

use crate::canvas_edges::{Rig, edge, end, rig};
use crate::canvas_ops::fixtures::{edit_op, id, move_op, remove, stroke};

const BOARD_MESSAGE: &str = "object must lie inside the board (-960,-540)-(2880,1620)";

fn object(kind: &str, at: (f64, f64, f64, f64)) -> Value {
    let mut body = stroke(&id());
    body["kind"] = json!(kind);
    body["x"] = json!(at.0);
    body["y"] = json!(at.1);
    body["w"] = json!(at.2);
    body["h"] = json!(at.3);
    if kind == "shape" {
        body["props"] = json!({ "primitive": "rect", "color": "annotation" });
    }
    body
}

async fn post(rig: &Rig, path: &str, body: Value) -> (StatusCode, Value) {
    let response = rig
        .app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/channels/{}/canvas/{path}", rig.channel))
                .header("authorization", format!("Bearer {}", rig.root))
                .header("content-type", "application/json")
                .body(Body::from(serde_json::to_vec(&body).unwrap()))
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

/// Old content: moves an object off the board the way an older server let it be.
async fn strand(rig: &Rig, object: &str, at: (f64, f64, f64, f64)) {
    let id = CanvasObjectId(Uuid::parse_str(object).unwrap());
    assert!(rig.store.move_canvas_object(id, at).await.unwrap());
}

async fn place_ok(rig: &Rig, kind: &str, at: (f64, f64, f64, f64)) -> String {
    let (status, body) = rig.place(&rig.root, object(kind, at)).await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
    body["id"].as_str().unwrap().to_owned()
}

async fn moved(rig: &Rig, object: &str, to: (f64, f64, f64, f64)) -> (StatusCode, Value) {
    rig.op(&rig.root, move_op(&id(), object, to)).await
}

#[tokio::test]
async fn a_place_outside_the_board_is_refused_and_one_on_it_is_not() {
    let rig = rig().await;
    for at in [
        (5000.0, 0.0, 10.0, 10.0),
        (-961.0, 0.0, 10.0, 10.0),
        (0.0, 1615.0, 10.0, 10.0),
        (2875.0, 0.0, 10.0, 10.0),
    ] {
        let (status, body) = rig.place(&rig.root, object("shape", at)).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{at:?} {body}");
        assert_eq!(body["error"], BOARD_MESSAGE);
    }
    place_ok(&rig, "shape", (-960.0, -540.0, 3840.0, 2160.0)).await;
    place_ok(&rig, "shape", (0.0, 0.0, 1920.0, 1080.0)).await;
}

#[tokio::test]
async fn a_batch_place_names_the_object_that_leaves_the_board() {
    let rig = rig().await;
    let objects = vec![
        object("shape", (0.0, 0.0, 10.0, 10.0)),
        object("shape", (3000.0, 0.0, 10.0, 10.0)),
    ];
    let (status, body) = post(&rig, "objects/batch", json!({ "objects": objects })).await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "{body}");
    assert!(
        body["error"].as_str().unwrap().contains("object 1"),
        "{body}"
    );
    assert!(
        body["error"].as_str().unwrap().contains(BOARD_MESSAGE),
        "{body}"
    );
    let (_, summary) = crate::canvas_agent_reads::get_json(&rig, "summary").await;
    assert_eq!(summary["count"], 0, "a refused batch writes nothing");
}

#[tokio::test]
async fn a_move_or_resize_off_the_board_is_refused_and_leaves_the_object() {
    let rig = rig().await;
    let shape = place_ok(&rig, "shape", (100.0, 100.0, 50.0, 50.0)).await;
    for to in [(2900.0, 100.0, 50.0, 50.0), (100.0, 100.0, 3000.0, 50.0)] {
        let (status, body) = moved(&rig, &shape, to).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{to:?} {body}");
        assert_eq!(body["error"], BOARD_MESSAGE);
    }
    let (status, body) = moved(&rig, &shape, (2000.0, 1000.0, 800.0, 600.0)).await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
}

#[tokio::test]
async fn a_batched_move_off_the_board_is_an_indexed_item_error() {
    let rig = rig().await;
    let shape = place_ok(&rig, "shape", (100.0, 100.0, 50.0, 50.0)).await;
    let ops = vec![
        move_op(&id(), &shape, (200.0, 200.0, 50.0, 50.0)),
        move_op(&id(), &shape, (9000.0, 200.0, 50.0, 50.0)),
    ];
    let (status, body) = post(&rig, "ops/batch", json!({ "ops": ops })).await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "{body}");
    assert_eq!(body["item_index"], 1, "{body}");
    assert_eq!(body["item_code"], "outside_board", "{body}");
    assert!(
        body["error"].as_str().unwrap().contains(BOARD_MESSAGE),
        "{body}"
    );
}

#[tokio::test]
async fn old_content_outside_can_be_brought_in_but_not_left_outside() {
    let rig = rig().await;
    let shape = place_ok(&rig, "shape", (0.0, 0.0, 50.0, 50.0)).await;
    strand(&rig, &shape, (6000.0, 0.0, 50.0, 50.0)).await;

    let (status, _) = moved(&rig, &shape, (4000.0, 0.0, 50.0, 50.0)).await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "closer but still outside");
    let (status, _) = moved(&rig, &shape, (9000.0, 0.0, 50.0, 50.0)).await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "further out");
    let (status, body) = moved(&rig, &shape, (100.0, 100.0, 50.0, 50.0)).await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
}

#[tokio::test]
async fn edits_reorders_and_removes_of_old_outside_content_are_never_refused() {
    let rig = rig().await;
    let note = rig.note(&rig.root, 0.0, 0.0).await;
    strand(&rig, &note, (6000.0, 0.0, 100.0, 50.0)).await;
    let (status, body) = rig
        .op(
            &rig.root,
            edit_op(&id(), &note, json!({ "text": "still here" })),
        )
        .await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
    let (status, body) = moved(&rig, &note, (6000.0, 0.0, 100.0, 50.0)).await;
    assert_eq!(
        status,
        StatusCode::CREATED,
        "an unchanged box changes nothing: {body}"
    );
    let (status, body) = rig.op(&rig.root, remove(&id(), &[&note])).await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
}

#[tokio::test]
async fn a_stroke_larger_than_the_board_is_refused_and_one_already_there_moves_no_further_out() {
    let rig = rig().await;
    let (status, body) = rig
        .place(&rig.root, object("stroke", (-960.0, 0.0, 4000.0, 10.0)))
        .await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "{body}");

    let stroke = place_ok(&rig, "stroke", (0.0, 0.0, 10.0, 10.0)).await;
    strand(&rig, &stroke, (-500.0, 0.0, 6000.0, 10.0)).await;
    let (status, _) = moved(&rig, &stroke, (500.0, 0.0, 6000.0, 10.0)).await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "further out");
    let (status, body) = moved(&rig, &stroke, (-1500.0, 0.0, 6000.0, 10.0)).await;
    assert_eq!(status, StatusCode::CREATED, "toward the board: {body}");
}

#[tokio::test]
async fn a_free_edge_end_must_lie_on_the_board() {
    let rig = rig().await;
    let a = rig.note(&rig.root, 0.0, 0.0).await;
    let (status, body) = rig
        .place(
            &rig.root,
            edge(&id(), end(&a), json!({ "x": 3000.0, "y": 0.0 })),
        )
        .await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "{body}");
    assert_eq!(
        body["error"],
        "a free edge end must lie inside the board (-960,-540)-(2880,1620)"
    );
    let (status, body) = rig
        .place(
            &rig.root,
            edge(&id(), end(&a), json!({ "x": 2880.0, "y": 1620.0 })),
        )
        .await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
}

#[tokio::test]
async fn an_old_edge_with_an_outside_end_can_be_relabelled_but_not_given_a_new_outside_end() {
    let rig = rig().await;
    let a = rig.note(&rig.root, 0.0, 0.0).await;
    let free = json!({ "x": 100.0, "y": 100.0 });
    let (_, placed) = rig.place(&rig.root, edge(&id(), end(&a), free)).await;
    let edge_id = placed["id"].as_str().unwrap().to_owned();
    let stored = json!({ "from": end(&a), "to": { "x": 9000.0, "y": 0.0 }, "arrow": "end" });
    sqlx::query("UPDATE canvas_object_props SET props = ? WHERE object_id = ?")
        .bind(stored.to_string())
        .bind(Uuid::parse_str(&edge_id).unwrap())
        .execute(&rig.pool)
        .await
        .unwrap();

    let label = edit_op(&id(), &edge_id, json!({ "label": "old" }));
    let (status, body) = rig.op(&rig.root, label).await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
    let farther = edit_op(&id(), &edge_id, json!({ "to": { "x": 9500.0, "y": 0.0 } }));
    let (status, _) = rig.op(&rig.root, farther).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let inside = edit_op(&id(), &edge_id, json!({ "to": { "x": 10.0, "y": 10.0 } }));
    let (status, body) = rig.op(&rig.root, inside).await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
}

#[tokio::test]
async fn the_summary_names_the_board() {
    let rig = rig().await;
    let (status, body) = crate::canvas_agent_reads::get_json(&rig, "summary").await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(
        body["board"],
        json!({ "min_x": -960.0, "min_y": -540.0, "max_x": 2880.0, "max_y": 1620.0 })
    );
}
