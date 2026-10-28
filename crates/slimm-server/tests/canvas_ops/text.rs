// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A `text` canvas object: placed and edited like a note, but its props are validated.

use axum::http::StatusCode;
use serde_json::{Value, json};

use crate::fixtures::{
    app, edit_op, general, get_ops, id, member, new_store, note, post_object, register, stroke,
    submit_op,
};

fn text(object_id: &str, props: Value) -> Value {
    json!({ "id": object_id, "kind": "text", "x": 10.0, "y": 20.0, "w": 200.0, "h": 40.0, "props": props })
}

fn good() -> Value {
    json!({ "text": "hello\nworld", "size": "medium", "color": "blue" })
}

async fn placed(props: Value) -> StatusCode {
    let (store, _guard) = new_store().await;
    register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());
    let (bob, _) = member(&store, "bob").await;
    post_object(&app, channel, &bob, text(&id(), props)).await.0
}

#[tokio::test]
async fn a_text_box_is_placed_edited_and_carried_by_the_op_log() {
    let (store, _guard) = new_store().await;
    register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());
    let (bob, _) = member(&store, "bob").await;
    let (status, body) = post_object(&app, channel, &bob, text(&id(), good())).await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
    assert_eq!(body["kind"], "text");
    let object = body["id"].as_str().unwrap().to_owned();

    let next = json!({ "text": "changed", "size": "large", "color": "green" });
    let (status, body) =
        submit_op(&app, channel, &bob, edit_op(&id(), &object, next.clone())).await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
    assert_eq!(body["op"]["affected"], 1);

    let (_, ops) = get_ops(&app, channel, &bob, "after_seq=0").await;
    let edit = ops["ops"]
        .as_array()
        .unwrap()
        .iter()
        .find(|op| op["kind"] == "edit")
        .unwrap();
    assert_eq!(edit["props"], next);
}

#[tokio::test]
async fn placing_text_that_is_empty_too_long_or_hidden_is_refused() {
    assert_eq!(
        placed(json!({ "text": "   " })).await,
        StatusCode::BAD_REQUEST
    );
    assert_eq!(
        placed(json!({ "size": "medium" })).await,
        StatusCode::BAD_REQUEST
    );
    assert_eq!(
        placed(json!({ "text": "x".repeat(501) })).await,
        StatusCode::BAD_REQUEST
    );
    assert_eq!(
        placed(json!({ "text": "x".repeat(500) })).await,
        StatusCode::CREATED
    );
    for hidden in ["a\u{202E}b", "a\u{200B}b", "a\u{0007}b", "a\tb"] {
        assert_eq!(
            placed(json!({ "text": hidden })).await,
            StatusCode::BAD_REQUEST,
            "{hidden:?}"
        );
    }
}

#[tokio::test]
async fn an_unknown_size_or_colour_is_refused() {
    assert_eq!(
        placed(json!({ "text": "a", "size": "huge" })).await,
        StatusCode::BAD_REQUEST
    );
    assert_eq!(
        placed(json!({ "text": "a", "size": 12 })).await,
        StatusCode::BAD_REQUEST
    );
    assert_eq!(
        placed(json!({ "text": "a", "color": "#ff0000" })).await,
        StatusCode::BAD_REQUEST
    );
    assert_eq!(
        placed(json!({ "text": "a", "color": "x".repeat(33) })).await,
        StatusCode::BAD_REQUEST
    );
}

#[tokio::test]
async fn editing_a_text_box_validates_the_new_props_and_a_stroke_cannot_be_edited() {
    let (store, pool, _guard) = crate::fixtures::new_store_and_pool().await;
    register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());
    let (bob, _) = member(&store, "bob").await;
    let (_, placed) = post_object(&app, channel, &bob, text(&id(), good())).await;
    let object = placed["id"].as_str().unwrap().to_owned();

    for bad in [
        json!({ "text": "a\u{202E}b" }),
        json!({ "text": "x".repeat(501) }),
        json!({ "text": "" }),
        json!({ "text": "a", "size": "nope" }),
    ] {
        let (status, body) = submit_op(&app, channel, &bob, edit_op(&id(), &object, bad)).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{body}");
    }
    let stored: String =
        sqlx::query_scalar("SELECT props FROM canvas_object_props WHERE object_id = ?")
            .bind(uuid::Uuid::parse_str(&object).unwrap())
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(serde_json::from_str::<Value>(&stored).unwrap(), good());

    let (_, ink) = post_object(&app, channel, &bob, stroke(&id())).await;
    let ink = ink["id"].as_str().unwrap().to_owned();
    let (status, _) = submit_op(&app, channel, &bob, edit_op(&id(), &ink, good())).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    let (_, sticky) = post_object(&app, channel, &bob, note(&id(), "free text")).await;
    let sticky = sticky["id"].as_str().unwrap().to_owned();
    let (status, _) = submit_op(
        &app,
        channel,
        &bob,
        edit_op(&id(), &sticky, json!({ "text": "a\u{202E}b" })),
    )
    .await;
    assert_eq!(
        status,
        StatusCode::CREATED,
        "a note keeps its own, looser props"
    );
}
