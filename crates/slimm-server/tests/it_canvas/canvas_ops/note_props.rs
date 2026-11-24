// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A note's style props: validated on place and edit, merged on edit so an older client's
//! text-only edit keeps the style (decision 0138).

use axum::http::StatusCode;
use serde_json::{Value, json};
use uuid::Uuid;

use crate::canvas_ops::fixtures::{
    app, edit_op, general, get_ops, id, member, new_store, new_store_and_pool, post_object,
    register, submit_op,
};

fn note_with(props: Value) -> Value {
    json!({ "id": id(), "kind": "note", "x": 10.0, "y": 20.0, "w": 220.0, "h": 140.0, "props": props })
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

#[tokio::test]
async fn the_payloads_shipped_clients_and_bots_send_still_place_and_edit() {
    let (store, _guard) = new_store().await;
    register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());
    let (bob, _) = member(&store, "bob").await;
    for first in [
        json!({ "text": "hi", "font_size": 14.0 }),
        json!({ "text": "homelab \u{1F468}\u{200D}\u{1F469}\ttab" }),
    ] {
        let (status, placed) = post_object(&app, channel, &bob, note_with(first)).await;
        assert_eq!(status, StatusCode::CREATED, "{placed}");
        let object = placed["id"].as_str().unwrap().to_owned();
        for next in [
            json!({ "text": "again", "font_size": 20.0 }),
            json!({ "text": "bot \u{1F468}\u{200D}\u{1F469}\ttab" }),
        ] {
            let (status, body) =
                submit_op(&app, channel, &bob, edit_op(&id(), &object, next)).await;
            assert_eq!(status, StatusCode::CREATED, "{body}");
        }
    }
}

#[tokio::test]
async fn bad_style_props_are_refused_on_place_and_on_edit() {
    let (store, _guard) = new_store().await;
    register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());
    let (bob, _) = member(&store, "bob").await;
    let (_, placed) = post_object(&app, channel, &bob, note_with(json!({ "text": "n" }))).await;
    let object = placed["id"].as_str().unwrap().to_owned();
    for bad in [
        json!({ "fill": "#fff" }),
        json!({ "color": 3 }),
        json!({ "size": "huge" }),
        json!({ "fill_opacity": 1.5 }),
        json!({ "fill_opacity": "x" }),
    ] {
        let mut props = bad.clone();
        props["text"] = json!("n");
        let (status, body) = post_object(&app, channel, &bob, note_with(props)).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "place {bad}: {body}");
        let (status, body) =
            submit_op(&app, channel, &bob, edit_op(&id(), &object, bad.clone())).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "edit {bad}: {body}");
    }
}

#[tokio::test]
async fn an_old_shape_edit_keeps_the_style_and_the_feed_carries_the_merged_props() {
    let (store, pool, _guard) = new_store_and_pool().await;
    register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());
    let (bob, _) = member(&store, "bob").await;
    let styled = json!({ "text": "a", "fill": "blue", "fill_opacity": 0.0, "color": "auto", "size": "large" });
    let (_, placed) = post_object(&app, channel, &bob, note_with(styled)).await;
    let object = placed["id"].as_str().unwrap().to_owned();

    let (status, body) = submit_op(
        &app,
        channel,
        &bob,
        edit_op(&id(), &object, json!({ "text": "b", "font_size": 20.0 })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
    let merged = json!({ "text": "b", "font_size": 20.0, "fill": "blue", "fill_opacity": 0.0, "color": "auto", "size": "large" });
    assert_eq!(props_of(&pool, &object).await, merged);
    let (_, ops) = get_ops(&app, channel, &bob, "after_seq=0").await;
    let edit = ops["ops"]
        .as_array()
        .unwrap()
        .iter()
        .find(|op| op["kind"] == "edit")
        .unwrap();
    assert_eq!(edit["props"], merged);
}

#[tokio::test]
async fn null_deletes_a_key_and_key_order_never_makes_an_edit() {
    let (store, pool, _guard) = new_store_and_pool().await;
    register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());
    let (bob, _) = member(&store, "bob").await;
    let (_, placed) = post_object(
        &app,
        channel,
        &bob,
        note_with(json!({ "text": "a", "fill": "blue", "size": "small" })),
    )
    .await;
    let object = placed["id"].as_str().unwrap().to_owned();

    let (_, body) = submit_op(
        &app,
        channel,
        &bob,
        edit_op(&id(), &object, json!({ "fill": null })),
    )
    .await;
    assert_eq!(body["op"]["affected"], 1, "{body}");
    assert_eq!(
        props_of(&pool, &object).await,
        json!({ "text": "a", "size": "small" })
    );

    let reordered: Value = serde_json::from_str(r#"{"size":"small","text":"a"}"#).unwrap();
    let (_, body) = submit_op(&app, channel, &bob, edit_op(&id(), &object, reordered)).await;
    assert_eq!(body["op"]["affected"], 0, "{body}");
}
