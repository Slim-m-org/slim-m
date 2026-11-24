// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Who may place, edit and erase a connection: the routes are shared with every canvas object, and
//! these keep an edge-specific branch from opening a hole unnoticed.

use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::permissions::Permissions;

use crate::canvas_ops::fixtures::{
    app, edit_op, general, id, member, new_store, note, post_object, register, remove, submit_op,
};

fn note_at(x: f64) -> Value {
    let mut body = note(&id(), "n");
    body["x"] = json!(x);
    body["y"] = json!(0.0);
    body["w"] = json!(100.0);
    body["h"] = json!(50.0);
    body
}

fn edge(from: &str, to: &str) -> Value {
    json!({
        "id": id(), "kind": "edge", "x": 0.0, "y": 0.0, "w": 1.0, "h": 1.0,
        "props": { "from": { "object_id": from }, "to": { "object_id": to }, "arrow": "end" },
    })
}

#[tokio::test]
async fn a_member_cannot_edit_or_erase_someone_elses_edge() {
    let (store, _guard) = new_store().await;
    let (root, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());
    let (bob, _) = member(&store, "bob").await;
    let (_, a) = post_object(&app, channel, &root, note_at(0.0)).await;
    let (_, b) = post_object(&app, channel, &root, note_at(300.0)).await;
    let (status, placed) = post_object(
        &app,
        channel,
        &root,
        edge(a["id"].as_str().unwrap(), b["id"].as_str().unwrap()),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{placed}");
    let e = placed["id"].as_str().unwrap().to_owned();

    let (status, body) = submit_op(
        &app,
        channel,
        &bob,
        edit_op(&id(), &e, json!({ "label": "mine" })),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN, "{body}");
    let (status, body) = submit_op(&app, channel, &bob, remove(&id(), &[&e])).await;
    assert_eq!(status, StatusCode::FORBIDDEN, "{body}");
}

#[tokio::test]
async fn a_member_denied_use_canvas_cannot_place_an_edge() {
    let (store, _guard) = new_store().await;
    let (root, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());
    let (bob, bob_id) = member(&store, "bob").await;
    let (_, a) = post_object(&app, channel, &root, note_at(0.0)).await;
    let (_, b) = post_object(&app, channel, &root, note_at(300.0)).await;
    store
        .set_member_overwrite(channel, bob_id, Permissions::NONE, Permissions::USE_CANVAS)
        .await
        .unwrap();

    let (status, body) = post_object(
        &app,
        channel,
        &bob,
        edge(a["id"].as_str().unwrap(), b["id"].as_str().unwrap()),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN, "{body}");
}
