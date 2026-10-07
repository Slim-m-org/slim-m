// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Placing a canvas object over HTTP: what it refuses, and what it promises a
//! caller who retries.
//!
//! The refusals are the point. This route sits behind a bit `@everyone` holds
//! by default and, in this slice, there is no way to remove what it writes, so
//! every ceiling here is one that cannot be walked back later.

use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::permissions::Permissions;
use slimm_server::store::{MAX_OBJECT_EXTENT, MAX_OBJECTS_PER_CHANNEL};
use tower::ServiceExt;
use uuid::Uuid;

use crate::fixtures::{
    QUERY, app, chrono_ms, general, id, new_store, new_store_and_pool, post, region, register,
    stroke,
};
use crate::support::canvas::{CanvasReads, remove_via_op};

#[tokio::test]
async fn a_placed_object_comes_straight_back_and_is_visible_to_a_viewport_read() {
    let (store, _guard) = new_store().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());

    let (status, body) = post(&app, channel, &token, stroke(&id())).await;
    assert_eq!(status, StatusCode::CREATED);
    assert_eq!(body["kind"], "stroke");
    assert_eq!(body["x"], 10.0);
    assert_eq!(body["seq"], 1);

    let objects = store
        .viewport_objects(
            channel,
            &slimm_server::store::ViewportQuery {
                view: slimm_server::store::Rect {
                    min_x: 0.0,
                    min_y: 0.0,
                    max_x: 100.0,
                    max_y: 100.0,
                },
                previous: None,
                after_seq: 0,
                limit: 10,
            },
        )
        .await
        .unwrap();
    assert_eq!(objects.len(), 1);
    assert_eq!(store.latest_canvas_seq(channel).await.unwrap(), 1);
}

/// Drawing is not the same permission as reading, and the write route has to
/// agree with the read route about that or the two disagree in the dangerous
/// direction: a member the viewport refuses could still add to the canvas.
#[tokio::test]
async fn placing_needs_the_canvas_bit_as_well_as_the_view_bit() {
    let (store, _guard) = new_store().await;
    let (_root, _root_id) = register(&store, "root").await;
    let channel = general(&store).await;

    let member = store
        .create_account("bob", "bob", "not-a-real-hash")
        .await
        .unwrap();
    let token = store
        .open_session(member.id, "cli")
        .await
        .unwrap()
        .access_token;
    store
        .set_member_overwrite(
            channel,
            member.id,
            Permissions::NONE,
            Permissions::USE_CANVAS,
        )
        .await
        .unwrap();

    let (status, _) = post(&app(store.clone()), channel, &token, stroke(&id())).await;
    assert_eq!(status, StatusCode::FORBIDDEN);
}

/// The bit a timeout cannot express. `TIMEOUT_DENY` spares `USE_CANVAS` on
/// purpose, so without this check a timed-out member keeps drawing.
#[tokio::test]
async fn a_timed_out_member_can_still_read_the_canvas_and_cannot_draw_on_it() {
    let (store, _guard) = new_store().await;
    let (_root, root_id) = register(&store, "root").await;
    let channel = general(&store).await;
    let member = store
        .create_account("bob", "bob", "not-a-real-hash")
        .await
        .unwrap();
    let token = store
        .open_session(member.id, "cli")
        .await
        .unwrap()
        .access_token;
    let app = app(store.clone());

    let (status, _) = post(&app, channel, &token, stroke(&id())).await;
    assert_eq!(
        status,
        StatusCode::CREATED,
        "drawing works before a timeout"
    );

    let until = chrono_ms() + 60_000;
    store
        .set_member_timeout(member.id, until, Some("cool off"), root_id)
        .await
        .unwrap();

    let (status, _) = post(&app, channel, &token, stroke(&id())).await;
    assert_eq!(status, StatusCode::FORBIDDEN);

    let permissions = store
        .permissions_in_channel(member.id, channel)
        .await
        .unwrap();
    assert!(
        permissions.contains(Permissions::USE_CANVAS),
        "the timeout must not blank the canvas, only freeze the pen",
    );
}

/// Decision 0004's other two tool-dock tools: neither carries a field this
/// route authorizes against, so both are plain rows once the allowlist knows
/// their names, the same as a stroke.
#[tokio::test]
async fn a_note_and_a_shape_are_both_accepted_object_kinds() {
    let (store, _guard) = new_store().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());

    let note = json!({
        "id": id(),
        "kind": "note",
        "x": 0.0, "y": 0.0, "w": 120.0, "h": 80.0,
        "props": { "text": "a reminder" },
    });
    let (status, body) = post(&app, channel, &token, note).await;
    assert_eq!(status, StatusCode::CREATED);
    assert_eq!(body["kind"], "note");

    let shape = json!({
        "id": id(),
        "kind": "shape",
        "x": 0.0, "y": 0.0, "w": 100.0, "h": 60.0,
        "props": { "shape": "rectangle" },
    });
    let (status, body) = post(&app, channel, &token, shape).await;
    assert_eq!(status, StatusCode::CREATED);
    assert_eq!(body["kind"], "shape");
}

/// The client's note sheet caps input at 1800 characters, chosen (per its own
/// doc comment) as "a comfortable margin" under the server's 4 KiB
/// `MAX_PROPS_BYTES`, on the assumption that JSON-escaping 1800 characters of
/// arbitrary text always fits. It does not: `serde_json` leaves any non-ASCII
/// byte unescaped, so a character that costs more than one UTF-8 byte costs
/// that many wire bytes for one unit of the client's own character count. A
/// note filled with ordinary CJK text - not a hostile string, just a
/// full-width script - already runs 3 bytes per character, and 1800 of them
/// (5,412 bytes once wrapped in `{"text":"..."}`) is refused here although
/// the client's own counter reads 1800/1800 and let the person submit.
#[tokio::test]
async fn a_note_at_the_clients_own_character_ceiling_can_still_be_refused_as_too_large() {
    let (store, _guard) = new_store().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store);

    let text: String = std::iter::repeat_n('\u{4e2d}', 1800).collect();
    let body = json!({
        "id": id(),
        "kind": "note",
        "x": 0.0, "y": 0.0, "w": 120.0, "h": 80.0,
        "props": { "text": text },
    });
    let encoded_props_bytes = serde_json::to_string(&json!({ "text": text }))
        .unwrap()
        .len();
    assert!(
        encoded_props_bytes > 4 * 1024,
        "the reproduction must actually exceed MAX_PROPS_BYTES: got {encoded_props_bytes}",
    );

    let (status, body) = post(&app, channel, &token, body).await;
    assert_eq!(
        status,
        StatusCode::BAD_REQUEST,
        "a client-legal 1800-character CJK note is still too large on the wire: {body}"
    );
}

#[tokio::test]
async fn an_unknown_kind_is_refused_rather_than_stored_as_a_row_nobody_can_draw() {
    let (store, _guard) = new_store().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let mut body = stroke(&id());
    body["kind"] = json!("window");

    let (status, _) = post(&app(store), channel, &token, body).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
}

/// Sized to sit between the props ceiling and the body limit, so only the
/// props check can be what refuses it: an earlier version of this test used a
/// body the byte-level limit rejected first, and dropping the props ceiling
/// left it green.
#[tokio::test]
async fn props_over_the_ceiling_are_refused_as_a_bad_request() {
    let (store, _guard) = new_store().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let mut body = stroke(&id());
    body["props"] = json!({ "points": vec![1.25_f64; 900] });
    assert!(
        (4 * 1024..8 * 1024).contains(&serde_json::to_vec(&body).unwrap().len()),
        "the body must be over the props ceiling and under the body limit",
    );

    let (status, _) = post(&app(store), channel, &token, body).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
}

/// Past the body limit it is refused at the byte level, before serde ever
/// builds a `Value` several times the wire size out of it.
#[tokio::test]
async fn an_over_large_body_is_refused_before_it_is_parsed() {
    let (store, _guard) = new_store().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let mut body = stroke(&id());
    body["props"] = json!({ "points": vec![1.25_f64; 4000] });

    let (status, _) = post(&app(store), channel, &token, body).await;
    assert_eq!(status, StatusCode::PAYLOAD_TOO_LARGE);
}

/// The world is bounded (owner decision) and so is one object inside it. An
/// object legally spanning the world is written into every cell of a client's
/// spatial grid, which is a hang rather than a slow frame.
#[tokio::test]
async fn an_object_outside_the_world_or_larger_than_the_ceiling_is_refused() {
    let (store, _guard) = new_store().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store);

    let mut outside = stroke(&id());
    outside["x"] = json!(4_999_999.0);
    outside["w"] = json!(100.0);
    let (status, _) = post(&app, channel, &token, outside).await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "outside the world");

    let mut huge = stroke(&id());
    huge["w"] = json!(MAX_OBJECT_EXTENT + 1.0);
    let (status, _) = post(&app, channel, &token, huge).await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "wider than the ceiling");
}

/// Idempotent by id, the way a message send is, and specifically not a second
/// row: the seq must be the first one, or a retry silently reorders the canvas.
#[tokio::test]
async fn the_same_id_twice_yields_one_object_with_its_original_seq() {
    let (store, _guard) = new_store().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());
    let object = id();

    let (first, first_body) = post(&app, channel, &token, stroke(&object)).await;
    let (_, _) = post(&app, channel, &token, stroke(&id())).await;
    let (second, second_body) = post(&app, channel, &token, stroke(&object)).await;

    assert_eq!(first, StatusCode::CREATED);
    assert_eq!(second, StatusCode::CREATED);
    assert_eq!(first_body["seq"], second_body["seq"]);
    assert_eq!(first_body["seq"], 1);
    assert_eq!(
        store.latest_canvas_seq(channel).await.unwrap(),
        2,
        "the replay must not consume a sequence value",
    );
}

#[tokio::test]
async fn the_same_id_in_another_channel_is_a_conflict() {
    let (store, _guard) = new_store().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let other = store.create_channel("other", "text").await.unwrap();
    let app = app(store);
    let object = id();

    let (first, _) = post(&app, channel, &token, stroke(&object)).await;
    let (second, body) = post(&app, other.id, &token, stroke(&object)).await;
    assert_eq!(first, StatusCode::CREATED);
    assert_eq!(second, StatusCode::CONFLICT);
    assert_eq!(body["error"], "canvas object id already used");
}

/// A retry racing an erase deserves an honest answer, not the same "id
/// taken" a foreign-channel conflict gets: the two 409s must read
/// differently, or a client cannot explain either to the person drawing.
#[tokio::test]
async fn replaying_the_id_of_a_removed_object_answers_a_distinct_conflict() {
    let (store, _guard) = new_store().await;
    let (token, user) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());
    let object = id();

    let (status, body) = post(&app, channel, &token, stroke(&object)).await;
    assert_eq!(status, StatusCode::CREATED);
    let placed = body["id"].as_str().unwrap().parse::<Uuid>().unwrap();
    remove_via_op(
        &store,
        channel,
        user,
        slimm_server::ids::CanvasObjectId(placed),
    )
    .await;

    let (status, body) = post(&app, channel, &token, stroke(&object)).await;
    assert_eq!(status, StatusCode::CONFLICT);
    assert_eq!(body["error"], "that object was removed");
    assert_ne!(
        body["error"], "canvas object id already used",
        "an erased-object retry must not read as a foreign-channel id conflict"
    );
}

/// A removed row keeps its id (the column is UNIQUE across live and dead
/// rows), so a replay that fell through to the insert would surface the
/// constraint violation as a 500 the moment anything ever removes an object.
#[tokio::test]
async fn replaying_the_id_of_a_removed_object_is_a_conflict_not_a_crash() {
    let (store, _guard) = new_store().await;
    let (token, user) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());
    let object = id();

    let (status, body) = post(&app, channel, &token, stroke(&object)).await;
    assert_eq!(status, StatusCode::CREATED);
    let placed = body["id"].as_str().unwrap().parse::<Uuid>().unwrap();
    remove_via_op(
        &store,
        channel,
        user,
        slimm_server::ids::CanvasObjectId(placed),
    )
    .await;

    let (status, _) = post(&app, channel, &token, stroke(&object)).await;
    assert_eq!(status, StatusCode::CONFLICT);
}

/// A truncated region must answer with the *newest* ink.
///
/// `z_index` is seeded from `seq`, so ordered ascending the limit dropped the
/// newest objects and kept a fixed prefix of old ones. That is invisible until
/// something writes: a busy region would then answer a reconnecting client
/// with everything except what had just been drawn, and the pane's recovery is
/// exactly a cold refetch.
#[tokio::test]
async fn a_truncated_region_answers_with_the_newest_objects() {
    let (store, _guard) = new_store().await;
    let (token, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = app(store.clone());

    for _ in 0..5 {
        let (status, _) = post(&app, channel, &token, stroke(&id())).await;
        assert_eq!(status, StatusCode::CREATED);
    }

    let response = app
        .clone()
        .oneshot(
            Request::builder()
                .method("GET")
                .uri(format!("{}?{}", region(channel), QUERY))
                .header("authorization", format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    let body: Value = serde_json::from_slice(&bytes).unwrap();

    assert_eq!(body["has_more"], true);
    let seqs: Vec<i64> = body["objects"]
        .as_array()
        .unwrap()
        .iter()
        .map(|o| o["seq"].as_i64().unwrap())
        .collect();
    assert_eq!(
        seqs,
        vec![4, 5],
        "the page must be the newest two, in paint order"
    );
}

/// The ceiling that cannot be walked back.
///
/// This slice ships no way to remove a canvas object - no erase, no
/// `MANAGE_CANVAS` path, no sweep - behind a bit `@everyone` holds, so an
/// unbounded write here would be permanent. Filled by raw insert rather than
/// twenty thousand round trips, since what is under test is the refusal.
#[tokio::test]
async fn a_full_canvas_refuses_the_next_object() {
    let (store, pool, _guard) = new_store_and_pool().await;
    let (token, author) = register(&store, "root").await;
    let channel = general(&store).await;

    sqlx::query(
        "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < ?)
         INSERT INTO canvas_objects
             (id, channel_id, channel_key, kind, z_index, x, y, w, h, props,
              author_id, seq, created_at)
         SELECT randomblob(16), ?, 0, 'stroke', i, 0, 0, 1, 1, '{}', ?, i, 0 FROM n",
    )
    .bind(MAX_OBJECTS_PER_CHANNEL)
    .bind(channel)
    .bind(author)
    .execute(&pool)
    .await
    .expect("filled the canvas");

    let (status, body) = post(&app(store), channel, &token, stroke(&id())).await;
    assert_eq!(status, StatusCode::CONFLICT);
    assert_eq!(body["error"], "this canvas is full");
}

/// The ceiling is the deployment's configured cap, not the compile-time
/// default. A cap of three refuses the fourth object even though the default is
/// twenty thousand: mutating the placement check to read `MAX_OBJECTS_PER_CHANNEL`
/// instead of the stored cap lets the fourth through and turns this red. Three
/// rows are inserted raw, since what is under test is the refusal, not the
/// placement round trip.
#[tokio::test]
async fn a_lowered_cap_refuses_the_next_object() {
    let (store, pool, _guard) = new_store_and_pool().await;
    let (token, author) = register(&store, "root").await;
    let channel = general(&store).await;
    store.set_canvas_object_cap(3).await.expect("set a low cap");

    sqlx::query(
        "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < ?)
         INSERT INTO canvas_objects
             (id, channel_id, channel_key, kind, z_index, x, y, w, h, props,
              author_id, seq, created_at)
         SELECT randomblob(16), ?, 0, 'stroke', i, 0, 0, 1, 1, '{}', ?, i, 0 FROM n",
    )
    .bind(3_i64)
    .bind(channel)
    .bind(author)
    .execute(&pool)
    .await
    .expect("filled the canvas to the low cap");

    let (status, body) = post(&app(store), channel, &token, stroke(&id())).await;
    assert_eq!(status, StatusCode::CONFLICT);
    assert_eq!(body["error"], "this canvas is full");
}
