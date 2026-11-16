// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A board stamp (decision 0121): the `emoji` object kind carries one reaction key and no
//! free text, cannot be edited into text, and a scoped clear can name it.

use axum::http::StatusCode;
use serde_json::{Value, json};

use crate::canvas_ops::fixtures::{
    app, edit_op, general, id, new_store_and_pool, post_object, register, submit_op,
};

fn emoji(id: &str, key: &str) -> Value {
    json!({
        "id": id, "kind": "emoji",
        "x": 10.0, "y": 20.0, "w": 130.0, "h": 130.0,
        "props": { "emoji": key },
    })
}

#[tokio::test]
async fn an_emoji_object_holds_one_reaction_key_and_nothing_else() {
    let (store, _pool, _guard) = new_store_and_pool().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());

    let (placed, body) = post_object(&app, channel, &token, emoji(&id(), "\u{1F389}")).await;
    let (shortcode, _) = post_object(&app, channel, &token, emoji(&id(), ":wave:")).await;
    let (text, refusal) = post_object(&app, channel, &token, emoji(&id(), "free text here")).await;
    let mut bare = emoji(&id(), "x");
    bare["props"] = json!({});
    let (missing, _) = post_object(&app, channel, &token, bare).await;

    assert_eq!(placed, StatusCode::CREATED, "{body}");
    assert_eq!(body["props"]["emoji"], "\u{1F389}");
    assert_eq!(shortcode, StatusCode::CREATED);
    assert_eq!(
        (text, missing),
        (StatusCode::BAD_REQUEST, StatusCode::BAD_REQUEST)
    );
    assert_eq!(refusal["error"], "an emoji object needs props.emoji");
}

#[tokio::test]
async fn an_emoji_object_cannot_be_edited_into_text() {
    let (store, _pool, _guard) = new_store_and_pool().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());
    let object = id();
    post_object(&app, channel, &token, emoji(&object, "\u{1F389}")).await;

    let edit = edit_op(&id(), &object, json!({ "emoji": "now a sentence" }));
    let (status, _) = submit_op(&app, channel, &token, edit).await;

    assert!(status.is_client_error(), "{status}");
}

#[tokio::test]
async fn a_clear_scoped_to_emoji_takes_only_the_stamps() {
    let (store, pool, _guard) = new_store_and_pool().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());
    post_object(&app, channel, &token, emoji(&id(), "\u{1F389}")).await;
    post_object(
        &app,
        channel,
        &token,
        crate::canvas_ops::fixtures::note(&id(), "keep"),
    )
    .await;

    let body = json!({
        "id": id(), "kind": "clear_scoped", "before_seq": 2, "kinds": ["emoji"],
    });
    let (status, out) = submit_op(&app, channel, &token, body).await;

    assert_eq!(status, StatusCode::CREATED, "{out}");
    assert_eq!(out["op"]["affected"], 1);
    let live: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM canvas_objects WHERE deleted_at IS NULL")
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(live, 1);
}
