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
    app, clear, edit_op, general, get_ops, id, member, move_op, new_store_and_pool, note,
    post_object, register, remove, reorder_op, restore, submit_op,
};

struct Rig {
    store: Store,
    pool: SqlitePool,
    app: Router,
    channel: ChannelId,
    root: String,
    root_id: UserId,
    _guard: crate::support::TestDbGuard,
}

async fn rig() -> Rig {
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

fn end(id: &str) -> Value {
    json!({ "object_id": id, "side": "right" })
}

fn edge(id: &str, from: Value, to: Value) -> Value {
    json!({
        "id": id, "kind": "edge", "x": 0.0, "y": 0.0, "w": 1.0, "h": 1.0,
        "props": { "from": from, "to": to, "arrow": "end" },
    })
}

fn note_at(id: &str, x: f64, y: f64) -> Value {
    let mut body = note(id, "n");
    body["x"] = json!(x);
    body["y"] = json!(y);
    body["w"] = json!(100.0);
    body["h"] = json!(50.0);
    body
}

impl Rig {
    async fn place(&self, token: &str, body: Value) -> (StatusCode, Value) {
        post_object(&self.app, self.channel, token, body).await
    }

    async fn note(&self, token: &str, x: f64, y: f64) -> String {
        let (status, body) = self.place(token, note_at(&id(), x, y)).await;
        assert_eq!(status, StatusCode::CREATED, "{body}");
        body["id"].as_str().unwrap().to_owned()
    }

    async fn connect(&self, token: &str, from: &str, to: &str) -> String {
        let (status, body) = self.place(token, edge(&id(), end(from), end(to))).await;
        assert_eq!(status, StatusCode::CREATED, "{body}");
        body["id"].as_str().unwrap().to_owned()
    }

    /// Through the store, so a fixture of dozens of objects is not also a rate-limit test.
    async fn quick(&self, kind: &str, bounds: (f64, f64, f64, f64), props: Value) -> String {
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

    async fn quick_note(&self, x: f64) -> String {
        self.quick("note", (x, 0.0, 100.0, 50.0), json!({ "text": "n" }))
            .await
    }

    async fn quick_edge(
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

    async fn op(&self, token: &str, body: Value) -> (StatusCode, Value) {
        submit_op(&self.app, self.channel, token, body).await
    }

    async fn is_live(&self, object: &str) -> bool {
        let deleted: Option<i64> =
            sqlx::query_scalar("SELECT deleted_at FROM canvas_objects WHERE id = ?")
                .bind(Uuid::parse_str(object).unwrap())
                .fetch_one(&self.pool)
                .await
                .unwrap();
        deleted.is_none()
    }

    async fn bounds(&self, object: &str) -> (f64, f64, f64, f64) {
        sqlx::query_as("SELECT x, y, w, h FROM canvas_objects WHERE id = ?")
            .bind(Uuid::parse_str(object).unwrap())
            .fetch_one(&self.pool)
            .await
            .unwrap()
    }

    async fn props(&self, object: &str) -> Value {
        let raw: String =
            sqlx::query_scalar("SELECT props FROM canvas_object_props WHERE object_id = ?")
                .bind(Uuid::parse_str(object).unwrap())
                .fetch_one(&self.pool)
                .await
                .unwrap();
        serde_json::from_str(&raw).unwrap()
    }

    async fn count(&self, sql: &str) -> i64 {
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
    let free = json!({ "x": 20_000.0, "y": 30_000.0 });
    let (status, placed) = rig.place(&rig.root, edge(&id(), end(&a), free)).await;
    assert_eq!(status, StatusCode::CREATED, "{placed}");
    assert_eq!(placed["w"].as_f64(), Some(20_000.0));
    assert_eq!(placed["h"].as_f64(), Some(30_000.0));
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

#[tokio::test]
async fn a_batch_refuses_an_edge() {
    let rig = rig().await;
    let a = rig.note(&rig.root, 0.0, 0.0).await;
    let b = rig.note(&rig.root, 200.0, 0.0).await;
    let response = rig
        .app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/channels/{}/canvas/objects/batch", rig.channel))
                .header("authorization", format!("Bearer {}", rig.root))
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::to_vec(&json!({ "objects": [edge(&id(), end(&a), end(&b))] }))
                        .unwrap(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn erasing_a_note_takes_its_edges_without_naming_them() {
    let rig = rig().await;
    let a = rig.note(&rig.root, 0.0, 0.0).await;
    let b = rig.note(&rig.root, 300.0, 0.0).await;
    let e = rig.connect(&rig.root, &a, &b).await;
    let (status, body) = rig.op(&rig.root, remove(&id(), &[&a])).await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
    assert_eq!(body["op"]["affected"], 1, "the op counts what was named");
    assert!(!rig.is_live(&e).await && rig.is_live(&b).await);
    let (_, ops) = get_ops(&rig.app, rig.channel, &rig.root, "after_seq=0").await;
    let removed = ops["ops"]
        .as_array()
        .unwrap()
        .iter()
        .find(|op| op["kind"] == "remove")
        .unwrap();
    assert_eq!(
        removed["object_ids"],
        json!([a]),
        "the feed names only the erased note"
    );
    assert_eq!(
        rig.count("SELECT COUNT(*) FROM canvas_op_cascades").await,
        1
    );
}

#[tokio::test]
async fn the_remove_of_sixty_four_notes_with_edges_keeps_its_frame_at_sixty_four_ids() {
    let rig = rig().await;
    let hub = rig.quick_note(0.0).await;
    let mut notes = Vec::new();
    for i in 0..64 {
        let n = rig.quick_note(200.0 + f64::from(i) * 120.0).await;
        rig.quick_edge(&hub, &n).await.unwrap();
        notes.push(n);
    }
    let refs: Vec<&str> = notes.iter().map(String::as_str).collect();
    let (status, body) = rig.op(&rig.root, remove(&id(), &refs)).await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
    assert_eq!(body["op"]["affected"], 64);
    let head = rig.count("SELECT MAX(seq) FROM canvas_ops").await;
    let (_, ops) = get_ops(
        &rig.app,
        rig.channel,
        &rig.root,
        &format!("after_seq={}", head - 1),
    )
    .await;
    let removed = ops["ops"]
        .as_array()
        .unwrap()
        .iter()
        .find(|op| op["kind"] == "remove")
        .unwrap();
    assert_eq!(removed["object_ids"].as_array().unwrap().len(), 64);
    assert_eq!(
        rig.count("SELECT COUNT(*) FROM canvas_objects WHERE kind = 'edge' AND deleted_at IS NULL")
            .await,
        0
    );
}

#[tokio::test]
async fn undoing_an_erase_brings_the_edges_back_and_not_one_whose_other_end_is_gone() {
    let rig = rig().await;
    let a = rig.note(&rig.root, 0.0, 0.0).await;
    let b = rig.note(&rig.root, 300.0, 0.0).await;
    let c = rig.note(&rig.root, 600.0, 0.0).await;
    let ab = rig.connect(&rig.root, &a, &b).await;
    let ac = rig.connect(&rig.root, &a, &c).await;
    let op = id();
    rig.op(&rig.root, remove(&op, &[&a])).await;
    rig.op(&rig.root, remove(&id(), &[&c])).await;
    let (status, body) = rig.op(&rig.root, restore(&id(), &op)).await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
    assert!(rig.is_live(&a).await && rig.is_live(&ab).await);
    assert!(!rig.is_live(&ac).await, "its other end is still erased");
}

#[tokio::test]
async fn a_member_undoing_their_own_erase_revives_edges_other_people_drew() {
    let rig = rig().await;
    let (bob, _) = member(&rig.store, "bob").await;
    let a = rig.note(&bob, 0.0, 0.0).await;
    let b = rig.note(&rig.root, 300.0, 0.0).await;
    let by_root = rig.connect(&rig.root, &a, &b).await;
    let op = id();
    let (status, _) = rig.op(&bob, remove(&op, &[&a])).await;
    assert_eq!(status, StatusCode::CREATED);
    assert!(!rig.is_live(&by_root).await);
    let (status, body) = rig.op(&bob, restore(&id(), &op)).await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
    assert!(
        rig.is_live(&by_root).await,
        "bob needs no say over root's edge"
    );
    assert_eq!(body["op"]["affected"], 2);
}

#[tokio::test]
async fn undoing_a_clear_revives_edges_newer_than_its_fence() {
    let rig = rig().await;
    let a = rig.note(&rig.root, 0.0, 0.0).await;
    let b = rig.note(&rig.root, 300.0, 0.0).await;
    let fence: i64 = rig.count("SELECT MAX(seq) FROM canvas_objects").await;
    let newer = rig.connect(&rig.root, &a, &b).await;
    let op = id();
    let (status, body) = rig.op(&rig.root, clear(&op, fence)).await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
    assert!(
        !rig.is_live(&newer).await,
        "a clear leaves no edge with a dead end"
    );
    rig.op(&rig.root, restore(&id(), &op)).await;
    assert!(rig.is_live(&a).await && rig.is_live(&newer).await);
}

#[tokio::test]
async fn a_locked_edge_refuses_an_edit_but_an_erase_of_its_end_still_takes_it() {
    let rig = rig().await;
    let a = rig.note(&rig.root, 0.0, 0.0).await;
    let b = rig.note(&rig.root, 300.0, 0.0).await;
    let e = rig.connect(&rig.root, &a, &b).await;
    rig.store
        .set_canvas_object_lock(
            rig.channel,
            CanvasObjectId(Uuid::parse_str(&e).unwrap()),
            rig.root_id,
            true,
            true,
        )
        .await
        .unwrap();
    let (status, _) = rig
        .op(&rig.root, edit_op(&id(), &e, json!({ "label": "x" })))
        .await;
    assert_eq!(status, StatusCode::CONFLICT);
    rig.op(&rig.root, remove(&id(), &[&b])).await;
    assert!(!rig.is_live(&e).await);
}

#[tokio::test]
async fn the_sixty_fifth_edge_on_one_object_is_refused() {
    let rig = rig().await;
    let hub = rig.quick_note(0.0).await;
    for i in 0..64 {
        let n = rig.quick_note(200.0 + f64::from(i) * 120.0).await;
        rig.quick_edge(&hub, &n).await.unwrap();
    }
    let extra = rig.quick_note(5000.0).await;
    let (status, body) = rig
        .place(&rig.root, edge(&id(), end(&hub), end(&extra)))
        .await;
    assert_eq!(status, StatusCode::CONFLICT, "{body}");
    let free = json!({ "x": 5.0, "y": 5.0 });
    let (status, _) = rig.place(&rig.root, edge(&id(), end(&extra), free)).await;
    assert_eq!(status, StatusCode::CREATED, "other objects are unaffected");
}

#[tokio::test]
async fn editing_an_edge_merges_keeps_absent_keys_and_recomputes_the_hull() {
    let rig = rig().await;
    let a = rig.note(&rig.root, 0.0, 0.0).await;
    let b = rig.note(&rig.root, 300.0, 0.0).await;
    let far = rig.note(&rig.root, 1000.0, 500.0).await;
    let e = rig.connect(&rig.root, &a, &b).await;

    let (status, body) = rig
        .op(
            &rig.root,
            edit_op(&id(), &e, json!({ "label": "needs", "color": "amber" })),
        )
        .await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
    let props = rig.props(&e).await;
    assert_eq!(props["label"], "needs");
    assert_eq!(props["arrow"], "end", "an absent key keeps its value");
    assert_eq!(props["from"]["object_id"], a);

    rig.op(&rig.root, edit_op(&id(), &e, json!({ "label": null })))
        .await;
    assert!(rig.props(&e).await.get("label").is_none());

    let (status, noop) = rig
        .op(&rig.root, edit_op(&id(), &e, json!({ "arrow": "end" })))
        .await;
    assert_eq!(status, StatusCode::CREATED);
    assert_eq!(
        noop["op"]["affected"], 0,
        "a merge that changes nothing writes nothing"
    );

    rig.op(&rig.root, edit_op(&id(), &e, json!({ "to": end(&far) })))
        .await;
    assert_eq!(rig.bounds(&e).await, (0.0, 0.0, 1100.0, 550.0));
    let (status, _) = rig
        .op(
            &rig.root,
            edit_op(
                &id(),
                &e,
                json!({ "to": { "x": 1.0, "y": 1.0 }, "from": { "x": 2.0, "y": 2.0 } }),
            ),
        )
        .await;
    assert_eq!(
        status,
        StatusCode::BAD_REQUEST,
        "an edit cannot free both ends"
    );
}

#[tokio::test]
async fn an_edge_cannot_be_moved_but_follows_its_ends_when_they_move() {
    let rig = rig().await;
    let a = rig.note(&rig.root, 0.0, 0.0).await;
    let b = rig.note(&rig.root, 300.0, 0.0).await;
    let e = rig.connect(&rig.root, &a, &b).await;
    let (status, body) = rig
        .op(&rig.root, move_op(&id(), &e, (5.0, 5.0, 10.0, 10.0)))
        .await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "{body}");
    assert_eq!(rig.bounds(&e).await, (0.0, 0.0, 400.0, 50.0));

    rig.op(&rig.root, move_op(&id(), &b, (900.0, 400.0, 100.0, 50.0)))
        .await;
    assert_eq!(rig.bounds(&e).await, (0.0, 0.0, 1000.0, 450.0));
    let (status, _) = rig.op(&rig.root, reorder_op(&id(), &e, 5)).await;
    assert_eq!(status, StatusCode::CREATED, "an edge may be restacked");
}

#[tokio::test]
async fn purging_an_end_purges_the_dead_edges_attached_to_it() {
    let rig = rig().await;
    let a = rig.note(&rig.root, 0.0, 0.0).await;
    let b = rig.note(&rig.root, 300.0, 0.0).await;
    let e = rig.connect(&rig.root, &a, &b).await;
    rig.op(&rig.root, remove(&id(), &[&a])).await;
    rig.store
        .purge_canvas_object(rig.channel, CanvasObjectId(Uuid::parse_str(&a).unwrap()))
        .await
        .unwrap();
    assert_eq!(
        rig.count(&format!(
            "SELECT COUNT(*) FROM canvas_objects WHERE id = x'{}'",
            Uuid::parse_str(&e).unwrap().simple()
        ))
        .await,
        0
    );
    assert_eq!(rig.count("SELECT COUNT(*) FROM canvas_edge_ends").await, 0);
    assert_eq!(
        rig.count("SELECT COUNT(*) FROM canvas_op_cascades").await,
        0
    );
}
