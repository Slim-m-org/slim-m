// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `POST /channels/{id}/canvas/ops`: `remove` and `clear`, and everything
//! they share - density, idempotency, `MANAGE_CANVAS`, the timeout carve-out,
//! and the validation each kind requires.

use slimm_server::permissions::Permissions;
use uuid::Uuid;

use crate::fixtures::{
    app, clear, general, get_ops, id, member, new_store, new_store_and_pool, place, post_object,
    register, remove, stroke, submit_op,
};
use crate::support::canvas::CanvasReads;

/// The property the whole op stream rests on: every mutation, of any kind,
/// allocates exactly one seq and writes exactly one row, with no gap.
#[tokio::test]
async fn the_feed_is_dense_over_a_mix_of_place_remove_and_clear() {
    let (store, _guard) = new_store().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());

    let (_, a) = post_object(&app, channel, &token, stroke(&id())).await;
    let a_id = a["id"].as_str().unwrap().to_owned();
    post_object(&app, channel, &token, stroke(&id())).await; // seq 2
    submit_op(&app, channel, &token, remove(&id(), &[&a_id])).await; // seq 3
    post_object(&app, channel, &token, stroke(&id())).await; // seq 4
    submit_op(&app, channel, &token, clear(&id(), 4)).await; // seq 5

    let (status, body) = get_ops(&app, channel, &token, "after_seq=0").await;
    assert_eq!(status, axum::http::StatusCode::OK, "{body}");
    let ops = body["ops"].as_array().unwrap();
    let seqs: Vec<i64> = ops.iter().map(|o| o["seq"].as_i64().unwrap()).collect();
    assert_eq!(seqs, vec![1, 2, 3, 4, 5], "no gap across mixed kinds");
    let kinds: Vec<&str> = ops.iter().map(|o| o["kind"].as_str().unwrap()).collect();
    assert_eq!(kinds, vec!["place", "place", "remove", "place", "clear"]);
}

/// An op row exists only for a real state transition, or the stream stops
/// being dense and every client's replay stops being meaningful.
#[tokio::test]
async fn an_op_that_changes_nothing_allocates_no_seq_and_writes_no_row() {
    let (store, _guard) = new_store().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());

    let (_, placed) = post_object(&app, channel, &token, stroke(&id())).await;
    let placed_id = placed["id"].as_str().unwrap().to_owned();
    submit_op(&app, channel, &token, remove(&id(), &[&placed_id])).await;
    assert_eq!(store.latest_canvas_seq(channel).await.unwrap(), 2);

    // The object named is already dead: nothing changes.
    let (status, body) = submit_op(&app, channel, &token, remove(&id(), &[&placed_id])).await;
    assert_eq!(status, axum::http::StatusCode::CREATED, "{body}");
    assert_eq!(body["op"]["affected"], 0);
    assert_eq!(
        store.latest_canvas_seq(channel).await.unwrap(),
        2,
        "an affected-0 remove must not consume a seq"
    );

    // Nothing is at or below seq 0.
    let (status, body) = submit_op(&app, channel, &token, clear(&id(), 0)).await;
    assert_eq!(status, axum::http::StatusCode::CREATED, "{body}");
    assert_eq!(body["op"]["affected"], 0);
    assert_eq!(
        store.latest_canvas_seq(channel).await.unwrap(),
        2,
        "an affected-0 clear must not consume a seq either"
    );

    let (_, body) = get_ops(&app, channel, &token, "after_seq=0").await;
    assert_eq!(
        body["ops"].as_array().unwrap().len(),
        2,
        "neither no-op call left a row behind"
    );
}

/// A replay must not re-remove whatever a concurrent writer restored in the
/// meantime, and must answer with the op it actually wrote the first time.
#[tokio::test]
async fn a_replayed_op_id_returns_the_stored_op_and_writes_nothing_new() {
    let (store, _guard) = new_store().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());

    let (_, placed) = post_object(&app, channel, &token, stroke(&id())).await;
    let placed_id = placed["id"].as_str().unwrap().to_owned();
    let op_id = id();

    let (first_status, first_body) =
        submit_op(&app, channel, &token, remove(&op_id, &[&placed_id])).await;
    assert_eq!(first_status, axum::http::StatusCode::CREATED);
    assert_eq!(first_body["fresh"], true);
    assert_eq!(first_body["op"]["affected"], 1);

    let (second_status, second_body) =
        submit_op(&app, channel, &token, remove(&op_id, &[&placed_id])).await;
    assert_eq!(second_status, axum::http::StatusCode::CREATED);
    assert_eq!(second_body["fresh"], false, "a replay is not fresh");
    assert_eq!(second_body["op"]["seq"], first_body["op"]["seq"]);
    assert_eq!(second_body["op"]["affected"], first_body["op"]["affected"]);
    assert_eq!(
        store.latest_canvas_seq(channel).await.unwrap(),
        2,
        "a replay must not consume a second seq"
    );
}

/// `MANAGE_CANVAS` gets its only meaning here: without it a member may only
/// erase their own ink.
#[tokio::test]
async fn a_member_cannot_remove_anothers_object_but_a_moderator_can() {
    let (store, _guard) = new_store().await;
    let (root_token, _root_id) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());
    let (bob_token, bob_id) = member(&store, "bob").await;

    let (_, placed) = post_object(&app, channel, &root_token, stroke(&id())).await;
    let placed_id = placed["id"].as_str().unwrap().to_owned();

    let (status, body) = submit_op(&app, channel, &bob_token, remove(&id(), &[&placed_id])).await;
    assert_eq!(
        status,
        axum::http::StatusCode::FORBIDDEN,
        "an ordinary member cannot remove someone else's object: {body}"
    );

    let mods = store
        .create_role("mods", Permissions::MANAGE_CANVAS, false)
        .await
        .unwrap();
    store.assign_role(bob_id, mods).await.unwrap();
    let (status, body) = submit_op(&app, channel, &bob_token, remove(&id(), &[&placed_id])).await;
    assert_eq!(status, axum::http::StatusCode::CREATED, "{body}");
    assert_eq!(body["op"]["affected"], 1);
}

/// Erasing your own ink needs no bit beyond `USE_CANVAS`.
#[tokio::test]
async fn a_member_may_remove_their_own_object_with_no_special_bit() {
    let (store, _guard) = new_store().await;
    let (_root_token, _root_id) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());
    let (bob_token, _bob_id) = member(&store, "bob").await;

    let (_, placed) = post_object(&app, channel, &bob_token, stroke(&id())).await;
    let placed_id = placed["id"].as_str().unwrap().to_owned();

    let (status, body) = submit_op(&app, channel, &bob_token, remove(&id(), &[&placed_id])).await;
    assert_eq!(status, axum::http::StatusCode::CREATED, "{body}");
    assert_eq!(body["op"]["affected"], 1);
}

/// A timeout freezes the pen, not the eraser: refusing this would make a
/// timeout's effect "lock the defacement in place", which is backwards.
#[tokio::test]
async fn a_timed_out_member_may_still_remove_their_own_object() {
    let (store, _guard) = new_store().await;
    let (_root_token, root_id) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());
    let (bob_token, bob_id) = member(&store, "bob").await;

    let (_, placed) = post_object(&app, channel, &bob_token, stroke(&id())).await;
    let placed_id = placed["id"].as_str().unwrap().to_owned();

    let until = now_ms() + 60_000;
    store
        .set_member_timeout(bob_id, until, Some("cool off"), root_id)
        .await
        .unwrap();

    let (place_status, _) = post_object(&app, channel, &bob_token, stroke(&id())).await;
    assert_eq!(
        place_status,
        axum::http::StatusCode::FORBIDDEN,
        "a timeout still refuses placing"
    );

    let (remove_status, body) =
        submit_op(&app, channel, &bob_token, remove(&id(), &[&placed_id])).await;
    assert_eq!(
        remove_status,
        axum::http::StatusCode::CREATED,
        "a timeout must not refuse removing one's own object: {body}"
    );

    let permissions = store.permissions_in_channel(bob_id, channel).await.unwrap();
    assert!(
        permissions.contains(Permissions::USE_CANVAS),
        "the timeout must not have blanked the canvas"
    );
}

/// The fence: a clear must not reach past `before_seq`.
#[tokio::test]
async fn a_clear_does_not_touch_objects_placed_after_before_seq() {
    let (store, pool, _guard) = new_store_and_pool().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());

    post_object(&app, channel, &token, stroke(&id())).await; // seq 1
    post_object(&app, channel, &token, stroke(&id())).await; // seq 2
    post_object(&app, channel, &token, stroke(&id())).await; // seq 3

    let (status, body) = submit_op(&app, channel, &token, clear(&id(), 2)).await;
    assert_eq!(status, axum::http::StatusCode::CREATED, "{body}");
    assert_eq!(body["op"]["affected"], 2);

    let alive: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM canvas_objects WHERE channel_id = ? AND deleted_at IS NULL",
    )
    .bind(channel)
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(alive, 1, "only the object placed after before_seq survives");
}

/// One unremovable id must not leave an earlier, removable one in the same
/// batch gone while the request as a whole fails: `apply_remove` only ever
/// borrows the transaction, never owns it, so nothing it does can commit
/// ahead of `submit_canvas_op`'s own rollback-on-error.
#[tokio::test]
async fn a_refused_batch_leaves_the_removable_id_untouched() {
    let (store, pool, _guard) = new_store_and_pool().await;
    let (root_token, _root_id) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());
    let (bob_token, _bob_id) = member(&store, "bob").await;

    let (_, bobs) = post_object(&app, channel, &bob_token, stroke(&id())).await;
    let bobs_id = bobs["id"].as_str().unwrap().to_owned();
    let (_, roots) = post_object(&app, channel, &root_token, stroke(&id())).await;
    let roots_id = roots["id"].as_str().unwrap().to_owned();

    let (status, body) = submit_op(
        &app,
        channel,
        &bob_token,
        remove(&id(), &[&bobs_id, &roots_id]),
    )
    .await;
    assert_eq!(status, axum::http::StatusCode::FORBIDDEN, "{body}");

    let dead: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM canvas_objects WHERE id = ? AND deleted_at IS NOT NULL",
    )
    .bind(Uuid::parse_str(&bobs_id).unwrap())
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(
        dead, 0,
        "bob's own object must survive a batch the whole request refused"
    );
}

#[tokio::test]
async fn an_object_id_absent_from_this_channel_is_a_404() {
    let (store, _guard) = new_store().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());

    let (status, body) = submit_op(&app, channel, &token, remove(&id(), &[&id()])).await;
    assert_eq!(status, axum::http::StatusCode::NOT_FOUND, "{body}");
}

#[tokio::test]
async fn an_object_id_belonging_to_another_channel_is_also_a_404() {
    let (store, _guard) = new_store().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let other = store.create_channel("other", "voice").await.unwrap().id;
    let app = app(store.clone());

    let (_, placed) = post_object(&app, other, &token, stroke(&id())).await;
    let placed_id = placed["id"].as_str().unwrap().to_owned();

    let (status, body) = submit_op(&app, channel, &token, remove(&id(), &[&placed_id])).await;
    assert_eq!(status, axum::http::StatusCode::NOT_FOUND, "{body}");
}

#[tokio::test]
async fn an_unknown_op_kind_is_a_bad_request() {
    let (store, _guard) = new_store().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;

    let body = serde_json::json!({ "id": id(), "kind": "teleport", "object_ids": [id()] });
    let (status, _) = submit_op(&app(store), channel, &token, body).await;
    assert_eq!(status, axum::http::StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn an_empty_or_oversized_object_ids_is_refused() {
    let (store, _guard) = new_store().await;
    let (token, author) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());

    let empty = serde_json::json!({ "id": id(), "kind": "remove", "object_ids": [] });
    let (status, _) = submit_op(&app, channel, &token, empty).await;
    assert_eq!(status, axum::http::StatusCode::BAD_REQUEST, "empty batch");

    let mut ids = Vec::new();
    for _ in 0..65 {
        ids.push(place(&store, channel, author, 0).await.to_string());
    }
    let over = remove(&id(), &ids.iter().map(String::as_str).collect::<Vec<_>>());
    let (status, _) = submit_op(&app, channel, &token, over).await;
    assert_eq!(status, axum::http::StatusCode::BAD_REQUEST, "65 ids");
}

#[tokio::test]
async fn exactly_the_ceiling_of_ids_is_accepted() {
    let (store, _guard) = new_store().await;
    let (token, author) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());

    let mut ids = Vec::new();
    for _ in 0..64 {
        ids.push(place(&store, channel, author, 0).await.to_string());
    }
    let body = remove(&id(), &ids.iter().map(String::as_str).collect::<Vec<_>>());
    let (status, resp) = submit_op(&app, channel, &token, body).await;
    assert_eq!(status, axum::http::StatusCode::CREATED, "{resp}");
    assert_eq!(resp["op"]["affected"], 64);
}

#[tokio::test]
async fn a_clear_needs_manage_canvas() {
    let (store, _guard) = new_store().await;
    let (_root_token, _root_id) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());
    let (bob_token, _bob_id) = member(&store, "bob").await;

    let (status, body) = submit_op(&app, channel, &bob_token, clear(&id(), 1_000)).await;
    assert_eq!(status, axum::http::StatusCode::FORBIDDEN, "{body}");
}

#[tokio::test]
async fn clear_refuses_object_ids_and_remove_refuses_before_seq() {
    let (store, _guard) = new_store().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store);

    let clear_with_ids =
        serde_json::json!({ "id": id(), "kind": "clear", "before_seq": 1, "object_ids": [id()] });
    let (status, _) = submit_op(&app, channel, &token, clear_with_ids).await;
    assert_eq!(status, axum::http::StatusCode::BAD_REQUEST);

    let remove_with_before_seq =
        serde_json::json!({ "id": id(), "kind": "remove", "object_ids": [id()], "before_seq": 1 });
    let (status, _) = submit_op(&app, channel, &token, remove_with_before_seq).await;
    assert_eq!(status, axum::http::StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn a_negative_before_seq_is_refused() {
    let (store, _guard) = new_store().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;

    let (status, _) = submit_op(&app(store), channel, &token, clear(&id(), -1)).await;
    assert_eq!(status, axum::http::StatusCode::BAD_REQUEST);
}

/// The same anonymization `feed.rs` already proves for a `place` op's actor,
/// extended to the two kinds this file adds: nothing here is conditioned on
/// `kind`, but nothing proved that until something wrote one of these rows.
#[tokio::test]
async fn account_deletion_nulls_the_actor_id_of_a_remove_op() {
    let (store, _guard) = new_store().await;
    let (token, author) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());

    let (_, placed) = post_object(&app, channel, &token, stroke(&id())).await;
    let placed_id = placed["id"].as_str().unwrap().to_owned();
    submit_op(&app, channel, &token, remove(&id(), &[&placed_id])).await;

    store.delete_account(author).await.unwrap();

    // Deletion revokes the token above, so this reads through the store directly, as `feed.rs` does.
    let page = store.list_canvas_ops(channel, 1, 100).await.unwrap();
    assert_eq!(page.ops.len(), 1, "the remove op itself survives");
    assert_eq!(
        page.ops[0].actor_id, None,
        "a deleted account must not stay named as the actor of a canvas op"
    );
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
}
