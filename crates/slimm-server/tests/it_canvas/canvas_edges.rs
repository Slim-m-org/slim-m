// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Canvas edges (decision 0137): placing and editing a connection between objects, and what an
//! erase, a clear, a move, an undo and a purge do to the edges attached to the objects they touch.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::ids::{CanvasObjectId, ChannelId, UserId};
use slimm_server::store::{PlaceRequest, Store};
use sqlx::SqlitePool;
use tower::ServiceExt;
use uuid::Uuid;

use crate::canvas_ops::fixtures::{
    app, general, id, new_store_and_pool, note, post_object, register, submit_op,
};

pub(crate) struct Rig {
    pub(crate) store: Store,
    pub(crate) pool: SqlitePool,
    pub(crate) app: Router,
    pub(crate) channel: ChannelId,
    pub(crate) root: String,
    pub(crate) root_id: UserId,
    pub(crate) _guard: crate::support::TestDbGuard,
}

pub(crate) async fn rig() -> Rig {
    let (store, pool, guard) = new_store_and_pool().await;
    let (root, root_id) = register(&store, "root").await;
    let channel = general(&store).await;
    Rig {
        app: app(store.clone()),
        store,
        pool,
        channel,
        root,
        root_id,
        _guard: guard,
    }
}

pub(crate) fn end(id: &str) -> Value {
    json!({ "object_id": id, "side": "right" })
}

pub(crate) fn edge(id: &str, from: Value, to: Value) -> Value {
    json!({
        "id": id, "kind": "edge", "x": 0.0, "y": 0.0, "w": 1.0, "h": 1.0,
        "props": { "from": from, "to": to, "arrow": "end" },
    })
}

pub(crate) fn note_at(id: &str, x: f64, y: f64) -> Value {
    let mut body = note(id, "n");
    body["x"] = json!(x);
    body["y"] = json!(y);
    body["w"] = json!(100.0);
    body["h"] = json!(50.0);
    body
}

impl Rig {
    pub(crate) async fn place(&self, token: &str, body: Value) -> (StatusCode, Value) {
        post_object(&self.app, self.channel, token, body).await
    }

    pub(crate) async fn note(&self, token: &str, x: f64, y: f64) -> String {
        let (status, body) = self.place(token, note_at(&id(), x, y)).await;
        assert_eq!(status, StatusCode::CREATED, "{body}");
        body["id"].as_str().unwrap().to_owned()
    }

    pub(crate) async fn connect(&self, token: &str, from: &str, to: &str) -> String {
        let (status, body) = self.place(token, edge(&id(), end(from), end(to))).await;
        assert_eq!(status, StatusCode::CREATED, "{body}");
        body["id"].as_str().unwrap().to_owned()
    }

    /// Through the store, so a fixture of dozens of objects is not also a rate-limit test.
    pub(crate) async fn quick(
        &self,
        kind: &str,
        bounds: (f64, f64, f64, f64),
        props: Value,
    ) -> String {
        let id = CanvasObjectId::generate();
        self.store
            .place_canvas_object(
                self.channel,
                self.root_id,
                id,
                PlaceRequest {
                    kind,
                    bounds,
                    props: &props.to_string(),
                    attachment: None,
                },
            )
            .await
            .unwrap();
        id.to_string()
    }

    /// A note on the `slot`th cell of a grid that fits the board, 24 to a row.
    pub(crate) async fn quick_note(&self, slot: u32) -> String {
        let (col, row) = (slot % 24, slot / 24);
        let at = (
            -900.0 + f64::from(col) * 120.0,
            -500.0 + f64::from(row) * 80.0,
        );
        self.quick("note", (at.0, at.1, 100.0, 50.0), json!({ "text": "n" }))
            .await
    }

    pub(crate) async fn quick_edge(
        &self,
        from: &str,
        to: &str,
    ) -> Result<String, slimm_server::store::PlaceError> {
        let id = CanvasObjectId::generate();
        let props = json!({ "from": end(from), "to": end(to) }).to_string();
        self.store
            .place_canvas_object(
                self.channel,
                self.root_id,
                id,
                PlaceRequest {
                    kind: "edge",
                    bounds: (0.0, 0.0, 0.0, 0.0),
                    props: &props,
                    attachment: None,
                },
            )
            .await
            .map(|_| id.to_string())
    }

    pub(crate) async fn op(&self, token: &str, body: Value) -> (StatusCode, Value) {
        submit_op(&self.app, self.channel, token, body).await
    }

    pub(crate) async fn is_live(&self, object: &str) -> bool {
        let deleted: Option<i64> =
            sqlx::query_scalar("SELECT deleted_at FROM canvas_objects WHERE id = ?")
                .bind(Uuid::parse_str(object).unwrap())
                .fetch_one(&self.pool)
                .await
                .unwrap();
        deleted.is_none()
    }

    pub(crate) async fn bounds(&self, object: &str) -> (f64, f64, f64, f64) {
        sqlx::query_as("SELECT x, y, w, h FROM canvas_objects WHERE id = ?")
            .bind(Uuid::parse_str(object).unwrap())
            .fetch_one(&self.pool)
            .await
            .unwrap()
    }

    pub(crate) async fn props(&self, object: &str) -> Value {
        let raw: String =
            sqlx::query_scalar("SELECT props FROM canvas_object_props WHERE object_id = ?")
                .bind(Uuid::parse_str(object).unwrap())
                .fetch_one(&self.pool)
                .await
                .unwrap();
        serde_json::from_str(&raw).unwrap()
    }

    pub(crate) async fn count(&self, sql: &str) -> i64 {
        sqlx::query_scalar(sqlx::AssertSqlSafe(sql.to_owned()))
            .fetch_one(&self.pool)
            .await
            .unwrap()
    }
}

#[tokio::test]
async fn an_edge_between_two_notes_stores_the_hull_the_server_derives() {
    let rig = rig().await;
    let a = rig.note(&rig.root, 0.0, 0.0).await;
    let b = rig.note(&rig.root, 300.0, 100.0).await;
    let (status, placed) = rig.place(&rig.root, edge(&id(), end(&a), end(&b))).await;
    assert_eq!(status, StatusCode::CREATED, "{placed}");
    assert_eq!(placed["kind"], "edge");
    let hull = (&placed["x"], &placed["y"], &placed["w"], &placed["h"]);
    assert_eq!(
        (
            hull.0.as_f64(),
            hull.1.as_f64(),
            hull.2.as_f64(),
            hull.3.as_f64()
        ),
        (Some(0.0), Some(0.0), Some(400.0), Some(150.0)),
        "the client's own box is ignored"
    );
}

#[tokio::test]
async fn an_edge_may_leave_one_end_free_and_may_span_more_than_one_object_can() {
    let rig = rig().await;
    let a = rig.note(&rig.root, 0.0, 0.0).await;
    let free = json!({ "x": 2_000.0, "y": 1_500.0 });
    let (status, placed) = rig.place(&rig.root, edge(&id(), end(&a), free)).await;
    assert_eq!(status, StatusCode::CREATED, "{placed}");
    assert_eq!(placed["w"].as_f64(), Some(2_000.0));
    assert_eq!(placed["h"].as_f64(), Some(1_500.0));
}

#[tokio::test]
async fn an_edge_with_a_bad_shape_or_end_is_refused() {
    let rig = rig().await;
    let a = rig.note(&rig.root, 0.0, 0.0).await;
    let b = rig.note(&rig.root, 200.0, 0.0).await;
    let free = json!({ "x": 1.0, "y": 1.0 });
    let stroke_id = {
        let (_, s) = rig
            .place(&rig.root, crate::canvas_ops::fixtures::stroke(&id()))
            .await;
        s["id"].as_str().unwrap().to_owned()
    };
    let missing = id();
    for (body, want) in [
        (
            edge(&id(), free.clone(), free.clone()),
            StatusCode::BAD_REQUEST,
        ),
        (edge(&id(), end(&a), end(&a)), StatusCode::BAD_REQUEST),
        (
            edge(&id(), end(&a), end(&stroke_id)),
            StatusCode::BAD_REQUEST,
        ),
        (edge(&id(), end(&a), end(&missing)), StatusCode::NOT_FOUND),
    ] {
        let (status, response) = rig.place(&rig.root, body).await;
        assert_eq!(status, want, "{response}");
    }
    for props in [
        json!({ "from": end(&a), "to": end(&b), "arrow": "start" }),
        json!({ "from": end(&a), "to": end(&b), "label": "two\nlines" }),
        json!({ "from": end(&a), "to": end(&b), "text": "no" }),
    ] {
        let mut body = edge(&id(), end(&a), end(&b));
        body["props"] = props;
        let (status, response) = rig.place(&rig.root, body).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{response}");
    }
    // An edge cannot hang on another edge.
    let first = rig.connect(&rig.root, &a, &b).await;
    let (status, _) = rig
        .place(&rig.root, edge(&id(), end(&a), end(&first)))
        .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn an_end_in_another_channel_answers_like_a_missing_one() {
    let rig = rig().await;
    let other = rig
        .store
        .create_channel("elsewhere", "canvas")
        .await
        .unwrap();
    let foreign = CanvasObjectId::generate();
    rig.store
        .place_canvas_object(
            other.id,
            rig.root_id,
            foreign,
            PlaceRequest {
                kind: "note",
                bounds: (0.0, 0.0, 10.0, 10.0),
                props: "{\"text\":\"x\"}",
                attachment: None,
            },
        )
        .await
        .unwrap();
    let a = rig.note(&rig.root, 0.0, 0.0).await;
    let (status, _) = rig
        .place(&rig.root, edge(&id(), end(&a), end(&foreign.to_string())))
        .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}

impl Rig {
    async fn batch(&self, objects: Vec<Value>) -> (StatusCode, Value) {
        let response = self
            .app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(format!("/channels/{}/canvas/objects/batch", self.channel))
                    .header("authorization", format!("Bearer {}", self.root))
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
}

#[tokio::test]
async fn a_batch_places_an_edge_between_objects_on_the_board_or_placed_earlier() {
    let rig = rig().await;
    let a = rig.note(&rig.root, 0.0, 0.0).await;
    let (b, c) = (id(), id());
    let (status, body) = rig
        .batch(vec![
            note_at(&b, 200.0, 0.0),
            note_at(&c, 400.0, 0.0),
            edge(&id(), end(&a), end(&b)),
            edge(&id(), end(&b), end(&c)),
        ])
        .await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
    let placed = body["objects"].as_array().unwrap();
    assert_eq!(placed.len(), 4);
    assert_eq!(placed[2]["kind"], "edge");
    assert_eq!(placed[3]["x"].as_f64(), Some(200.0));
    assert_eq!(placed[3]["w"].as_f64(), Some(300.0));
    let ends = rig.count("SELECT COUNT(*) FROM canvas_edge_ends").await;
    assert_eq!(ends, 4);
}

#[tokio::test]
async fn a_batch_edge_naming_a_later_or_missing_object_is_a_400_and_places_nothing() {
    let rig = rig().await;
    let a = rig.note(&rig.root, 0.0, 0.0).await;
    let later = id();
    for body in [
        vec![
            note_at(&id(), 0.0, 300.0),
            edge(&id(), end(&a), end(&later)),
            note_at(&later, 200.0, 0.0),
        ],
        vec![note_at(&id(), 0.0, 300.0), edge(&id(), end(&a), end(&id()))],
    ] {
        let (status, response) = rig.batch(body).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{response}");
        let message = response["error"].as_str().unwrap();
        assert!(message.starts_with("object 1: "), "{message}");
    }
    assert_eq!(rig.count("SELECT COUNT(*) FROM canvas_objects").await, 1);
}

#[tokio::test]
async fn a_batch_edge_gets_every_check_a_single_edge_does() {
    let rig = rig().await;
    let a = rig.note(&rig.root, 0.0, 0.0).await;
    let b = rig.note(&rig.root, 200.0, 0.0).await;
    let (_, stroke) = rig
        .place(&rig.root, crate::canvas_ops::fixtures::stroke(&id()))
        .await;
    let stroke = stroke["id"].as_str().unwrap().to_owned();
    let free = json!({ "x": 1.0, "y": 1.0 });
    for (edge_body, want) in [
        (edge(&id(), end(&a), end(&a)), StatusCode::BAD_REQUEST),
        (edge(&id(), end(&a), end(&stroke)), StatusCode::BAD_REQUEST),
        (edge(&id(), free.clone(), free), StatusCode::BAD_REQUEST),
    ] {
        let (status, response) = rig.batch(vec![edge_body]).await;
        assert_eq!(status, want, "{response}");
        let message = response["error"].as_str().unwrap();
        assert!(message.starts_with("object 0: "), "{message}");
    }
    let mut full = Vec::new();
    for _ in 0..=slimm_server::canvas_edge::MAX_EDGES_PER_OBJECT {
        full.push(edge(&id(), end(&a), end(&b)));
    }
    let (status, response) = rig.batch(full).await;
    assert_eq!(status, StatusCode::CONFLICT, "{response}");
    assert!(
        response["error"]
            .as_str()
            .unwrap()
            .starts_with("object 64: ")
    );
}

#[tokio::test]
async fn a_retried_batch_with_edges_answers_with_the_stored_rows() {
    let rig = rig().await;
    let (a, b) = (id(), id());
    let objects = vec![
        note_at(&a, 0.0, 0.0),
        note_at(&b, 200.0, 0.0),
        edge(&id(), end(&a), end(&b)),
    ];
    let (first, one) = rig.batch(objects.clone()).await;
    let (second, two) = rig.batch(objects).await;
    assert_eq!((first, second), (StatusCode::CREATED, StatusCode::CREATED));
    assert_eq!(one, two);
    assert_eq!(rig.count("SELECT COUNT(*) FROM canvas_edge_ends").await, 2);
}
