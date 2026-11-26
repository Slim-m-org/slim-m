// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Canvas edges (decision 0137), part two: what an erase, a clear, an undo, a lock, an edit, a
//! move and a purge do to the edges attached to the objects they touch.

use axum::http::StatusCode;
use serde_json::json;
use slimm_server::ids::CanvasObjectId;
use uuid::Uuid;

use crate::canvas_edges::{edge, end, rig};
use crate::canvas_ops::fixtures::{
    clear, edit_op, get_ops, id, member, move_op, remove, reorder_op, restore,
};

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
