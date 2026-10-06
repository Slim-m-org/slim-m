// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `POST /channels/{id}/canvas/ops` with `kind: "reorder"`: authorship the
//! same way `move` gates it, the one place a timeout applies to this op
//! stream alongside `move`, and that a reorder touches only `z_index`.

use axum::http::StatusCode;
use serde_json::json;
use slimm_server::permissions::Permissions;
use uuid::Uuid;

use crate::fixtures::{
    app, general, id, member, new_store, new_store_and_pool, post_object, register, reorder_op,
    stroke, submit_op,
};
use crate::support::canvas::CanvasReads;

async fn bounds_and_z(pool: &sqlx::SqlitePool, object_id: &str) -> (f64, f64, f64, f64, i64) {
    sqlx::query_as("SELECT x, y, w, h, z_index FROM canvas_objects WHERE id = ?")
        .bind(Uuid::parse_str(object_id).unwrap())
        .fetch_one(pool)
        .await
        .unwrap()
}

#[tokio::test]
async fn a_member_may_reorder_their_own_object_with_no_special_bit() {
    let (store, pool, _guard) = new_store_and_pool().await;
    let (_root_token, _root_id) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());
    let (bob_token, _bob_id) = member(&store, "bob").await;

    let (_, placed) = post_object(&app, channel, &bob_token, stroke(&id())).await;
    let object_id = placed["id"].as_str().unwrap().to_owned();

    let (status, body) = submit_op(
        &app,
        channel,
        &bob_token,
        reorder_op(&id(), &object_id, 500),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
    assert_eq!(body["op"]["affected"], 1);
    assert_eq!(body["op"]["kind"], "reorder");

    let (_, _, _, _, z) = bounds_and_z(&pool, &object_id).await;
    assert_eq!(z, 500);
}

/// The shape `a_member_cannot_move_anothers_object_but_a_moderator_can`
/// already proves for `move`, extended to `reorder`.
#[tokio::test]
async fn a_member_cannot_reorder_anothers_object_but_a_moderator_can() {
    let (store, _guard) = new_store().await;
    let (root_token, _root_id) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());
    let (bob_token, bob_id) = member(&store, "bob").await;

    let (_, placed) = post_object(&app, channel, &root_token, stroke(&id())).await;
    let object_id = placed["id"].as_str().unwrap().to_owned();

    let (status, body) =
        submit_op(&app, channel, &bob_token, reorder_op(&id(), &object_id, 42)).await;
    assert_eq!(
        status,
        StatusCode::FORBIDDEN,
        "an ordinary member cannot reorder someone else's object: {body}"
    );

    let mods = store
        .create_role("mods", Permissions::MANAGE_CANVAS, false)
        .await
        .unwrap();
    store.assign_role(bob_id, mods).await.unwrap();
    let (status, body) =
        submit_op(&app, channel, &bob_token, reorder_op(&id(), &object_id, 42)).await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
    assert_eq!(body["op"]["affected"], 1);
}

/// Authorization must be checked before liveness, the same fix `move`'s own
/// equivalent test guards: a non-moderator naming someone else's
/// already-removed object must get `FORBIDDEN`, not `CREATED` with
/// `affected: 0`, or reorder becomes a free is-this-object-dead oracle for
/// anyone holding `USE_CANVAS` and nothing more.
#[tokio::test]
async fn a_member_cannot_learn_anothers_object_is_dead_by_reordering_it() {
    let (store, _guard) = new_store().await;
    let (root_token, _root_id) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());
    let (bob_token, _bob_id) = member(&store, "bob").await;

    let (_, placed) = post_object(&app, channel, &root_token, stroke(&id())).await;
    let object_id = placed["id"].as_str().unwrap().to_owned();
    submit_op(
        &app,
        channel,
        &root_token,
        crate::fixtures::remove(&id(), &[&object_id]),
    )
    .await;

    let (status, body) =
        submit_op(&app, channel, &bob_token, reorder_op(&id(), &object_id, 1)).await;
    assert_eq!(
        status,
        StatusCode::FORBIDDEN,
        "a dead foreign object must refuse the same way a live one does: {body}"
    );
}

/// The other place a timeout reaches this op stream, beside `move`: reorder
/// changes how ink presents rather than removing it, so the pen's freeze
/// applies here too, unlike `remove`, `clear` and `restore`.
#[tokio::test]
async fn a_timed_out_member_cannot_reorder_their_own_object() {
    let (store, _guard) = new_store().await;
    let (_root_token, root_id) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());
    let (bob_token, bob_id) = member(&store, "bob").await;

    let (_, placed) = post_object(&app, channel, &bob_token, stroke(&id())).await;
    let object_id = placed["id"].as_str().unwrap().to_owned();

    let until = now_ms() + 60_000;
    store
        .set_member_timeout(bob_id, until, Some("cool off"), root_id)
        .await
        .unwrap();

    let (status, body) =
        submit_op(&app, channel, &bob_token, reorder_op(&id(), &object_id, 9)).await;
    assert_eq!(
        status,
        StatusCode::FORBIDDEN,
        "a timeout must freeze reorder the same way it freezes move: {body}"
    );
}

/// Racing an erase: an honest retry deserves a truthful answer, not an
/// error, the same reasoning `PlaceError::Removed` and `move`'s own
/// already-removed handling document.
#[tokio::test]
async fn reordering_an_already_removed_object_answers_affected_zero() {
    let (store, _guard) = new_store().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());

    let (_, placed) = post_object(&app, channel, &token, stroke(&id())).await;
    let object_id = placed["id"].as_str().unwrap().to_owned();
    submit_op(
        &app,
        channel,
        &token,
        crate::fixtures::remove(&id(), &[&object_id]),
    )
    .await;

    let (status, body) = submit_op(&app, channel, &token, reorder_op(&id(), &object_id, 1)).await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
    assert_eq!(body["op"]["affected"], 0);
}

#[tokio::test]
async fn an_object_id_absent_from_this_channel_is_a_404() {
    let (store, _guard) = new_store().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;

    let (status, body) = submit_op(&app(store), channel, &token, reorder_op(&id(), &id(), 1)).await;
    assert_eq!(status, StatusCode::NOT_FOUND, "{body}");
}

#[tokio::test]
async fn an_object_id_belonging_to_another_channel_is_also_a_404() {
    let (store, _guard) = new_store().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let other = store.create_channel("other", "voice").await.unwrap().id;
    let app = app(store.clone());

    let (_, placed) = post_object(&app, other, &token, stroke(&id())).await;
    let object_id = placed["id"].as_str().unwrap().to_owned();

    let (status, body) = submit_op(&app, channel, &token, reorder_op(&id(), &object_id, 1)).await;
    assert_eq!(status, StatusCode::NOT_FOUND, "{body}");
}

/// A reorder must not disturb `x`, `y`, `w` or `h`, or `props` - only
/// `z_index`. Any `i64` is legal, including negative (send-to-back).
#[tokio::test]
async fn reordering_does_not_touch_bounds_or_props_and_accepts_a_negative_value() {
    let (store, pool, _guard) = new_store_and_pool().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());

    let (_, placed) = post_object(&app, channel, &token, stroke(&id())).await;
    let object_id = placed["id"].as_str().unwrap().to_owned();
    let (before_x, before_y, before_w, before_h, _) = bounds_and_z(&pool, &object_id).await;

    submit_op(&app, channel, &token, reorder_op(&id(), &object_id, -100)).await;

    let (x, y, w, h, z) = bounds_and_z(&pool, &object_id).await;
    assert_eq!((x, y, w, h), (before_x, before_y, before_w, before_h));
    assert_eq!(
        z, -100,
        "a negative z_index (send to back) must be accepted"
    );

    let props: String = sqlx::query_scalar("SELECT props FROM canvas_objects WHERE id = ?")
        .bind(Uuid::parse_str(&object_id).unwrap())
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(
        props,
        serde_json::to_string(
            &json!({ "points": [0.0, 0.0, 30.0, 40.0], "width": 3.0, "color": "annotation" })
        )
        .unwrap()
    );
}

#[tokio::test]
async fn a_replayed_reorder_returns_the_stored_op_and_writes_nothing_new() {
    let (store, _guard) = new_store().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());

    let (_, placed) = post_object(&app, channel, &token, stroke(&id())).await;
    let object_id = placed["id"].as_str().unwrap().to_owned();
    let op_id = id();

    let (first_status, first_body) =
        submit_op(&app, channel, &token, reorder_op(&op_id, &object_id, 10)).await;
    assert_eq!(first_status, StatusCode::CREATED);
    assert_eq!(first_body["fresh"], true);

    let (second_status, second_body) = submit_op(
        &app,
        channel,
        &token,
        // A different z_index than the first call: a replay must ignore it.
        reorder_op(&op_id, &object_id, 999),
    )
    .await;
    assert_eq!(second_status, StatusCode::CREATED);
    assert_eq!(second_body["fresh"], false, "a replay is not fresh");
    assert_eq!(second_body["op"]["seq"], first_body["op"]["seq"]);
    assert_eq!(
        store.latest_canvas_seq(channel).await.unwrap(),
        2,
        "a replay must not consume a second seq"
    );
}

#[tokio::test]
async fn account_deletion_nulls_the_actor_id_of_a_reorder_op() {
    let (store, _guard) = new_store().await;
    let (token, author) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());

    let (_, placed) = post_object(&app, channel, &token, stroke(&id())).await;
    let object_id = placed["id"].as_str().unwrap().to_owned();
    submit_op(&app, channel, &token, reorder_op(&id(), &object_id, 7)).await;

    store.delete_account(author).await.unwrap();

    let page = store.list_canvas_ops(channel, 1, 100).await.unwrap();
    assert_eq!(page.ops.len(), 1, "the reorder op itself survives");
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
