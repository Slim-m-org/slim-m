// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Who a canvas frame reaches: both `VIEW_CHANNEL` and `USE_CANVAS`, and
//! never a member an overwrite denied the canvas.

use std::time::Duration;

use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::http;
use slimm_server::permissions::Permissions;
use tower::ServiceExt;
use uuid::Uuid;

use crate::fixtures::{connect, new_store, post_json, read_frame, serve, user_ticket};
use crate::requests::{
    clear_request, move_request, place_request, remove_request, reorder_request, restore_request,
    scoped_clear_request,
};
use crate::support;

/// The load-bearing one. Carol holds `VIEW_CHANNEL` and is denied `USE_CANVAS`
/// by a member overwrite, so she reads the channel and must never be handed a
/// canvas frame; a cache that only remembers the view bit delivers to her.
#[tokio::test]
async fn a_canvas_frame_needs_both_bits_and_a_denied_member_never_sees_one() {
    let (store, _guard) = new_store().await;
    let state = support::app::state(store.clone());
    let (alice_access, alice_ticket, alice) = user_ticket(&store, "alice").await;
    store.bootstrap_deployment(alice).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;

    let (_carol_access, carol_ticket, carol) = user_ticket(&store, "carol").await;
    store
        .set_member_overwrite(channel, carol, Permissions::NONE, Permissions::USE_CANVAS)
        .await
        .unwrap();

    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut carol_ws = connect(addr, &carol_ticket).await;

    let response = http::router(state.clone())
        .oneshot(place_request(channel, &alice_access))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::CREATED);

    let frame = read_frame(&mut alice_ws).await;
    assert_eq!(frame["type"], "canvas.object.placed");
    assert_eq!(frame["channel_id"], channel.to_string());
    assert_eq!(frame["seq"], 1);
    assert_eq!(frame["object"]["kind"], "stroke");
    assert_eq!(frame["object"]["x"], 4.0);

    let carol_next =
        tokio::time::timeout(Duration::from_millis(300), read_frame(&mut carol_ws)).await;
    assert!(
        carol_next.is_err(),
        "carol is denied USE_CANVAS and must not receive canvas frames",
    );
}

/// The same load-bearing property as the placement test above, for the five
/// other frames: a member an overwrite denies `USE_CANVAS` must receive
/// neither a removal, a clear, a restore, a move, nor a reorder, exactly as
/// she receives no placement. Extends the reachability guard `extra_bit`
/// exists for:
/// reverting it to a `matches!` naming only `CanvasObjectPlaced` fails this
/// the moment any one of the five fires.
#[tokio::test]
async fn a_removal_a_clear_a_restore_a_move_and_a_reorder_need_both_bits_and_a_denied_member_never_sees_any()
 {
    let (store, _guard) = new_store().await;
    let state = support::app::state(store.clone());
    let (alice_access, alice_ticket, alice) = user_ticket(&store, "alice").await;
    store.bootstrap_deployment(alice).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;

    let (_carol_access, carol_ticket, carol) = user_ticket(&store, "carol").await;
    store
        .set_member_overwrite(channel, carol, Permissions::NONE, Permissions::USE_CANVAS)
        .await
        .unwrap();

    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut carol_ws = connect(addr, &carol_ticket).await;

    let placed = http::router(state.clone())
        .oneshot(place_request(channel, &alice_access))
        .await
        .unwrap();
    assert_eq!(placed.status(), StatusCode::CREATED);
    let bytes = axum::body::to_bytes(placed.into_body(), usize::MAX)
        .await
        .unwrap();
    let placed: Value = serde_json::from_slice(&bytes).unwrap();
    let object_id = placed["id"].as_str().unwrap().to_owned();
    assert_eq!(
        read_frame(&mut alice_ws).await["type"],
        "canvas.object.placed"
    );

    let removed = http::router(state.clone())
        .oneshot(remove_request(channel, &alice_access, &object_id))
        .await
        .unwrap();
    assert_eq!(removed.status(), StatusCode::CREATED);
    let bytes = axum::body::to_bytes(removed.into_body(), usize::MAX)
        .await
        .unwrap();
    let removed_body: Value = serde_json::from_slice(&bytes).unwrap();
    let remove_op_id = removed_body["op"]["id"].as_str().unwrap().to_owned();
    let frame = read_frame(&mut alice_ws).await;
    assert_eq!(frame["type"], "canvas.objects.removed");
    assert_eq!(frame["channel_id"], channel.to_string());
    assert_eq!(frame["object_ids"], json!([object_id]));

    let cleared = http::router(state.clone())
        .oneshot(clear_request(channel, &alice_access, 1))
        .await
        .unwrap();
    assert_eq!(cleared.status(), StatusCode::CREATED);
    // Nothing is below seq 1 yet, so this is an affected-0 no-op; place a second object to clear for real.
    let placed_again = http::router(state.clone())
        .oneshot(place_request(channel, &alice_access))
        .await
        .unwrap();
    assert_eq!(placed_again.status(), StatusCode::CREATED);
    assert_eq!(
        read_frame(&mut alice_ws).await["type"],
        "canvas.object.placed"
    );

    let cleared = http::router(state.clone())
        .oneshot(clear_request(channel, &alice_access, 100))
        .await
        .unwrap();
    assert_eq!(cleared.status(), StatusCode::CREATED);
    let frame = read_frame(&mut alice_ws).await;
    assert_eq!(frame["type"], "canvas.cleared");
    assert_eq!(frame["before_seq"], 100);

    let restored = http::router(state.clone())
        .oneshot(restore_request(channel, &alice_access, &remove_op_id))
        .await
        .unwrap();
    assert_eq!(restored.status(), StatusCode::CREATED);
    let frame = read_frame(&mut alice_ws).await;
    assert_eq!(frame["type"], "canvas.objects.restored");
    assert_eq!(frame["channel_id"], channel.to_string());
    assert_eq!(frame["object_ids"], json!([object_id]));

    // Restored above, so it is live again and movable.
    let moved = http::router(state.clone())
        .oneshot(move_request(channel, &alice_access, &object_id))
        .await
        .unwrap();
    assert_eq!(moved.status(), StatusCode::CREATED);
    let frame = read_frame(&mut alice_ws).await;
    assert_eq!(frame["type"], "canvas.object.moved");
    assert_eq!(frame["channel_id"], channel.to_string());
    assert_eq!(frame["object_id"], object_id);
    assert_eq!(frame["x"], 9.0);

    let reordered = http::router(state.clone())
        .oneshot(reorder_request(channel, &alice_access, &object_id))
        .await
        .unwrap();
    assert_eq!(reordered.status(), StatusCode::CREATED);
    let frame = read_frame(&mut alice_ws).await;
    assert_eq!(frame["type"], "canvas.object.reordered");
    assert_eq!(frame["channel_id"], channel.to_string());
    assert_eq!(frame["object_id"], object_id);
    assert_eq!(frame["z_index"], 500);

    // A scoped clear must not reuse `canvas.cleared`: a client that predates scopes would read it as clear-everything.
    let scoped = http::router(state.clone())
        .oneshot(scoped_clear_request(channel, &alice_access))
        .await
        .unwrap();
    assert_eq!(scoped.status(), StatusCode::CREATED);
    let frame = read_frame(&mut alice_ws).await;
    assert_eq!(frame["type"], "canvas.cleared_scoped");
    assert_eq!(frame["kinds"], json!(["stroke"]));

    let carol_next =
        tokio::time::timeout(Duration::from_millis(300), read_frame(&mut carol_ws)).await;
    assert!(
        carol_next.is_err(),
        "carol is denied USE_CANVAS and must receive none of a removal, a clear, a restore, a move, or a reorder",
    );
}

/// An edited note reaches everyone with USE_CANVAS carrying its new props,
/// and nobody without it (decision 0072).
#[tokio::test]
async fn an_edited_note_reaches_the_channel_with_its_new_props() {
    let (store, _guard) = new_store().await;
    let state = support::app::state(store.clone());
    let (alice_access, alice_ticket, alice) = user_ticket(&store, "alice").await;
    store.bootstrap_deployment(alice).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;
    let (_carol_access, carol_ticket, carol) = user_ticket(&store, "carol").await;
    store
        .set_member_overwrite(channel, carol, Permissions::NONE, Permissions::USE_CANVAS)
        .await
        .unwrap();

    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut carol_ws = connect(addr, &carol_ticket).await;

    let note_id = Uuid::now_v7().to_string();
    let placed = http::router(state.clone())
        .oneshot(post_json(
            &format!("/channels/{channel}/canvas/objects"),
            &alice_access,
            json!({ "id": note_id, "kind": "note", "x": 0.0, "y": 0.0, "w": 220.0, "h": 140.0,
                    "props": { "text": "before" } }),
        ))
        .await
        .unwrap();
    assert_eq!(placed.status(), StatusCode::CREATED);
    assert_eq!(
        read_frame(&mut alice_ws).await["type"],
        "canvas.object.placed"
    );

    let edited = http::router(state.clone())
        .oneshot(post_json(
            &format!("/channels/{channel}/canvas/ops"),
            &alice_access,
            json!({ "id": Uuid::now_v7().to_string(), "kind": "edit", "object_id": note_id,
                    "props": { "text": "after" } }),
        ))
        .await
        .unwrap();
    assert_eq!(edited.status(), StatusCode::CREATED);
    let frame = read_frame(&mut alice_ws).await;
    assert_eq!(frame["type"], "canvas.object.edited");
    assert_eq!(frame["object_id"], note_id);
    assert_eq!(frame["props"]["text"], "after");

    let carol_next =
        tokio::time::timeout(Duration::from_millis(300), read_frame(&mut carol_ws)).await;
    assert!(
        carol_next.is_err(),
        "carol has no USE_CANVAS and must not see the edit"
    );
}
