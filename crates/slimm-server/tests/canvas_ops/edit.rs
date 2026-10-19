// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `POST /channels/{id}/canvas/ops` with `kind: "edit"`: a note's props
//! replaced after placement (decision 0072), gated like a move.

use axum::http::StatusCode;
use serde_json::json;
use slimm_server::ids::CanvasObjectId;
use slimm_server::permissions::Permissions;
use uuid::Uuid;

use crate::fixtures::{
    app, edit_op, general, get_ops, id, member, new_store, new_store_and_pool, note, post_object,
    register, stroke, submit_op,
};

async fn props_of(pool: &sqlx::SqlitePool, object_id: &str) -> serde_json::Value {
    let raw: String = sqlx::query_scalar("SELECT props FROM canvas_objects WHERE id = ?")
        .bind(Uuid::parse_str(object_id).unwrap())
        .fetch_one(pool)
        .await
        .unwrap();
    serde_json::from_str(&raw).unwrap()
}

#[tokio::test]
async fn a_member_edits_their_own_note_and_the_op_log_carries_it() {
    let (store, pool, _guard) = new_store_and_pool().await;
    register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());
    let (bob, _) = member(&store, "bob").await;
    let (_, placed) = post_object(&app, channel, &bob, note(&id(), "first")).await;
    let object = placed["id"].as_str().unwrap().to_owned();

    let new_props = json!({ "text": "**second** @alice", "color": "annotation" });
    let (status, body) = submit_op(
        &app,
        channel,
        &bob,
        edit_op(&id(), &object, new_props.clone()),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
    assert_eq!(body["op"]["kind"], "edit");
    assert_eq!(body["op"]["affected"], 1);
    assert_eq!(props_of(&pool, &object).await, new_props);

    let (status, ops) = get_ops(&app, channel, &bob, "after_seq=0").await;
    assert_eq!(status, StatusCode::OK, "{ops}");
    let edit = ops["ops"]
        .as_array()
        .unwrap()
        .iter()
        .find(|op| op["kind"] == "edit")
        .expect("the edit is in the op log");
    assert_eq!(edit["object_id"], object);
    assert_eq!(edit["props"], new_props);
}

#[tokio::test]
async fn editing_to_the_same_props_changes_nothing() {
    let (store, _guard) = new_store().await;
    register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());
    let (bob, _) = member(&store, "bob").await;
    let (_, placed) = post_object(&app, channel, &bob, note(&id(), "same")).await;
    let object = placed["id"].as_str().unwrap().to_owned();

    let (status, body) = submit_op(
        &app,
        channel,
        &bob,
        edit_op(
            &id(),
            &object,
            json!({ "text": "same", "color": "annotation" }),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
    assert_eq!(body["op"]["affected"], 0);
}

#[tokio::test]
async fn only_the_author_or_a_canvas_moderator_may_edit_a_note() {
    let (store, _guard) = new_store().await;
    let (root, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());
    let (bob, bob_id) = member(&store, "bob").await;
    let (_, placed) = post_object(&app, channel, &root, note(&id(), "root's")).await;
    let object = placed["id"].as_str().unwrap().to_owned();

    let (status, body) = submit_op(
        &app,
        channel,
        &bob,
        edit_op(&id(), &object, json!({ "text": "bob" })),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN, "{body}");

    let mods = store
        .create_role("mods", Permissions::MANAGE_CANVAS, false)
        .await
        .unwrap();
    store.assign_role(bob_id, mods).await.unwrap();
    let (status, body) = submit_op(
        &app,
        channel,
        &bob,
        edit_op(&id(), &object, json!({ "text": "bob" })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
}

#[tokio::test]
async fn only_a_note_can_be_edited() {
    let (store, _guard) = new_store().await;
    register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());
    let (bob, _) = member(&store, "bob").await;
    let (_, placed) = post_object(&app, channel, &bob, stroke(&id())).await;
    let object = placed["id"].as_str().unwrap().to_owned();

    let (status, body) = submit_op(
        &app,
        channel,
        &bob,
        edit_op(&id(), &object, json!({ "text": "x" })),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "{body}");
}

#[tokio::test]
async fn an_edit_over_the_props_limit_or_without_props_is_refused() {
    let (store, _guard) = new_store().await;
    register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());
    let (bob, _) = member(&store, "bob").await;
    let (_, placed) = post_object(&app, channel, &bob, note(&id(), "n")).await;
    let object = placed["id"].as_str().unwrap().to_owned();

    let huge = "x".repeat(5000);
    let (status, body) = submit_op(
        &app,
        channel,
        &bob,
        edit_op(&id(), &object, json!({ "text": huge })),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "{body}");

    let (status, body) = submit_op(
        &app,
        channel,
        &bob,
        json!({ "id": id(), "kind": "edit", "object_id": object }),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "{body}");
}

#[tokio::test]
async fn a_locked_note_refuses_an_edit_even_from_its_author() {
    let (store, pool, _guard) = new_store_and_pool().await;
    register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());
    let (bob, bob_id) = member(&store, "bob").await;
    let (_, placed) = post_object(&app, channel, &bob, note(&id(), "pinned")).await;
    let object = placed["id"].as_str().unwrap().to_owned();
    let object_id = CanvasObjectId(Uuid::parse_str(&object).unwrap());
    store
        .set_canvas_object_lock(channel, object_id, bob_id, false, true)
        .await
        .unwrap();

    let (status, body) = submit_op(
        &app,
        channel,
        &bob,
        edit_op(&id(), &object, json!({ "text": "x" })),
    )
    .await;
    assert_eq!(status, StatusCode::CONFLICT, "{body}");
    assert_eq!(props_of(&pool, &object).await["text"], "pinned");
}
