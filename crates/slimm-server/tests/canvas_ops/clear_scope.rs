// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A scoped `clear`: narrowed by object kind and/or author, still one op that
//! one `restore` undoes, and replayed with its scope by the op feed.

use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::store::CanvasOpBody;

use crate::fixtures::{
    app, general, get_ops, id, member, new_store_and_pool, note, post_object, register, restore,
    stroke, submit_op,
};

async fn live_ids(pool: &sqlx::SqlitePool, kind: &str) -> i64 {
    sqlx::query_scalar("SELECT COUNT(*) FROM canvas_objects WHERE deleted_at IS NULL AND kind = ?")
        .bind(kind)
        .fetch_one(pool)
        .await
        .unwrap()
}

fn scoped(op_id: &str, before_seq: i64, extra: Value) -> Value {
    let mut body = json!({ "id": op_id, "kind": "clear_scoped", "before_seq": before_seq });
    body.as_object_mut()
        .unwrap()
        .extend(extra.as_object().unwrap().clone());
    body
}

#[tokio::test]
async fn a_clear_scoped_to_one_kind_leaves_the_others() {
    let (store, pool, _guard) = new_store_and_pool().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());
    post_object(&app, channel, &token, stroke(&id())).await;
    post_object(&app, channel, &token, stroke(&id())).await;
    post_object(&app, channel, &token, note(&id(), "hi")).await;

    let body = scoped(&id(), 3, json!({ "kinds": ["stroke"] }));
    let (status, out) = submit_op(&app, channel, &token, body).await;
    assert_eq!(status, StatusCode::CREATED, "{out}");
    assert_eq!(out["op"]["affected"], 2);
    assert_eq!(live_ids(&pool, "stroke").await, 0);
    assert_eq!(live_ids(&pool, "note").await, 1);
}

#[tokio::test]
async fn a_clear_scoped_to_an_author_leaves_everyone_elses_objects() {
    let (store, pool, _guard) = new_store_and_pool().await;
    let (root_token, root) = register(&store, "root").await;
    let (ann_token, _) = member(&store, "ann").await;
    let channel = general(&store).await;
    let app = app(store.clone());
    post_object(&app, channel, &root_token, stroke(&id())).await;
    post_object(&app, channel, &ann_token, stroke(&id())).await;
    post_object(&app, channel, &root_token, stroke(&id())).await;

    let body = scoped(&id(), 3, json!({ "author_id": root.to_string() }));
    let (status, out) = submit_op(&app, channel, &root_token, body).await;
    assert_eq!(status, StatusCode::CREATED, "{out}");
    assert_eq!(out["op"]["affected"], 2);
    assert_eq!(live_ids(&pool, "stroke").await, 1);
}

#[tokio::test]
async fn undoing_a_scoped_clear_restores_only_what_it_removed() {
    let (store, pool, _guard) = new_store_and_pool().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());
    post_object(&app, channel, &token, stroke(&id())).await;
    post_object(&app, channel, &token, note(&id(), "hi")).await;
    let (_, first) = submit_op(
        &app,
        channel,
        &token,
        scoped(&id(), 2, json!({ "kinds": ["stroke"] })),
    )
    .await;
    let (_, second) = submit_op(
        &app,
        channel,
        &token,
        scoped(&id(), 2, json!({ "kinds": ["note"] })),
    )
    .await;
    assert_eq!(second["op"]["affected"], 1);

    let target = first["op"]["id"].as_str().unwrap();
    let (status, out) = submit_op(&app, channel, &token, restore(&id(), target)).await;
    assert_eq!(status, StatusCode::CREATED, "{out}");
    assert_eq!(out["op"]["affected"], 1);
    assert_eq!(live_ids(&pool, "stroke").await, 1);
    assert_eq!(live_ids(&pool, "note").await, 0, "the other clear stays");
}

#[tokio::test]
async fn a_scoped_clear_still_needs_manage_canvas() {
    let (store, _pool, _guard) = new_store_and_pool().await;
    register(&store, "root").await;
    let (ann_token, ann) = member(&store, "ann").await;
    let channel = general(&store).await;
    let app = app(store.clone());
    post_object(&app, channel, &ann_token, stroke(&id())).await;

    let body = scoped(&id(), 1, json!({ "author_id": ann.to_string() }));
    let (status, _) = submit_op(&app, channel, &ann_token, body).await;
    assert_eq!(status, StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn the_feed_carries_the_scope_so_a_replay_narrows_the_same_way() {
    let (store, _pool, _guard) = new_store_and_pool().await;
    let (token, root) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());
    post_object(&app, channel, &token, stroke(&id())).await;
    let body = scoped(
        &id(),
        1,
        json!({ "kinds": ["stroke", "image"], "author_id": root.to_string() }),
    );
    submit_op(&app, channel, &token, body).await;

    let page = store.list_canvas_ops(channel, 0, 100).await.unwrap();
    match &page.ops[1].body {
        CanvasOpBody::Clear { scope, .. } => {
            assert_eq!(scope.kinds, ["stroke", "image"]);
            assert_eq!(scope.author_id, Some(root));
        }
        other => panic!("expected Clear, got {other:?}"),
    }
}

#[tokio::test]
async fn scope_fields_are_validated() {
    let (store, _pool, _guard) = new_store_and_pool().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());
    for extra in [
        json!({ "kinds": ["window"] }),
        json!({ "author_id": "not-a-uuid" }),
    ] {
        let (status, _) = submit_op(&app, channel, &token, scoped(&id(), 1, extra)).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
    }
    let plain_with_scope = json!({
        "id": id(), "kind": "clear", "before_seq": 1, "kinds": ["stroke"],
    });
    let (status, _) = submit_op(&app, channel, &token, plain_with_scope).await;
    assert_eq!(
        status,
        StatusCode::BAD_REQUEST,
        "a plain clear never carries a scope"
    );
    let empty_scope = json!({ "id": id(), "kind": "clear_scoped", "before_seq": 1 });
    let (status, _) = submit_op(&app, channel, &token, empty_scope).await;
    assert_eq!(
        status,
        StatusCode::BAD_REQUEST,
        "a scoped clear names its scope"
    );
    let remove_with_scope = json!({
        "id": id(), "kind": "remove", "object_ids": [id()], "kinds": ["stroke"],
    });
    let (status, _) = submit_op(&app, channel, &token, remove_with_scope).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
}

/// An older client reads `kind: clear` as clear-everything and an unknown kind as "resync"; only the latter is safe.
#[tokio::test]
async fn a_scoped_clear_is_never_served_as_kind_clear_over_http() {
    let (store, _pool, _guard) = new_store_and_pool().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());
    post_object(&app, channel, &token, stroke(&id())).await;
    post_object(&app, channel, &token, note(&id(), "hi")).await;
    submit_op(
        &app,
        channel,
        &token,
        scoped(&id(), 2, json!({ "kinds": ["note"] })),
    )
    .await;
    let plain = json!({ "id": id(), "kind": "clear", "before_seq": 2 });
    submit_op(&app, channel, &token, plain).await;

    let (_, page) = get_ops(&app, channel, &token, "after_seq=0").await;
    let kinds: Vec<&str> = page["ops"]
        .as_array()
        .unwrap()
        .iter()
        .map(|op| op["kind"].as_str().unwrap())
        .collect();
    assert_eq!(kinds, ["place", "place", "clear_scoped", "clear"]);
    assert_eq!(page["ops"][2]["kinds"], json!(["note"]));
}
