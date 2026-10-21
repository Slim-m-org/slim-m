// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The live `canvas.object.lock_changed` frame: one per real change, nothing
//! for a repeat, nothing for a member denied the canvas, and a timeout stops
//! locking and editing.

use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::http;
use slimm_server::ids::ChannelId;
use slimm_server::permissions::Permissions;
use tower::ServiceExt;
use uuid::Uuid;

use crate::fixtures::{connect, new_store, post_json, read_frame, serve, user_ticket};
use crate::support;

fn lock_request(method: &str, channel: ChannelId, token: &str, object_id: &str) -> Request<Body> {
    Request::builder()
        .method(method)
        .uri(format!(
            "/channels/{channel}/canvas/objects/{object_id}/lock"
        ))
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap()
}

async fn place_note(state: &http::AppState, channel: ChannelId, token: &str) -> String {
    let body = json!({
        "id": Uuid::now_v7().to_string(), "kind": "note",
        "x": 1.0, "y": 1.0, "w": 100.0, "h": 60.0,
        "props": { "text": "hi", "color": "annotation" },
    });
    let request = post_json(&format!("/channels/{channel}/canvas/objects"), token, body);
    let response = http::router(state.clone()).oneshot(request).await.unwrap();
    assert_eq!(response.status(), StatusCode::CREATED);
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    let placed: Value = serde_json::from_slice(&bytes).unwrap();
    placed["id"].as_str().unwrap().to_owned()
}

async fn status_of(state: &http::AppState, request: Request<Body>) -> StatusCode {
    http::router(state.clone())
        .oneshot(request)
        .await
        .unwrap()
        .status()
}

#[tokio::test]
async fn a_lock_publishes_once_a_repeat_publishes_nothing_and_a_denied_member_sees_neither() {
    let (store, _guard) = new_store().await;
    let state = support::app::state(store.clone());
    let (alice_access, alice_ticket, alice) = user_ticket(&store, "alice").await;
    store.bootstrap_deployment(alice).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;
    let (_bob_access, bob_ticket, _bob) = user_ticket(&store, "bob").await;
    let (_carol_access, carol_ticket, carol) = user_ticket(&store, "carol").await;
    store
        .set_member_overwrite(channel, carol, Permissions::NONE, Permissions::USE_CANVAS)
        .await
        .unwrap();
    let addr = serve(state.clone()).await;
    let _alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;
    let mut carol_ws = connect(addr, &carol_ticket).await;
    let object = place_note(&state, channel, &alice_access).await;
    assert_eq!(
        read_frame(&mut bob_ws).await["type"],
        "canvas.object.placed"
    );

    for method in ["PUT", "PUT"] {
        let request = lock_request(method, channel, &alice_access, &object);
        assert_eq!(status_of(&state, request).await, StatusCode::NO_CONTENT);
    }
    let request = lock_request("DELETE", channel, &alice_access, &object);
    assert_eq!(status_of(&state, request).await, StatusCode::NO_CONTENT);

    let locked = read_frame(&mut bob_ws).await;
    assert_eq!(locked["type"], "canvas.object.lock_changed");
    assert_eq!(
        (locked["object_id"].as_str(), locked["locked"].as_bool()),
        (Some(object.as_str()), Some(true))
    );
    let unlocked = read_frame(&mut bob_ws).await;
    assert_eq!(
        unlocked["locked"], false,
        "the repeat lock published a second frame"
    );

    let message = post_json(
        &format!("/channels/{channel}/messages"),
        &alice_access,
        json!({ "id": Uuid::now_v7().to_string(), "content": "after" }),
    );
    assert_eq!(status_of(&state, message).await, StatusCode::OK);
    let first_for_carol = read_frame(&mut carol_ws).await;
    assert_eq!(
        first_for_carol["type"], "message.created",
        "{first_for_carol}"
    );
}

#[tokio::test]
async fn a_timed_out_member_can_neither_lock_unlock_nor_edit() {
    let (store, _guard) = new_store().await;
    let state = support::app::state(store.clone());
    let (alice_access, _alice_ticket, alice) = user_ticket(&store, "alice").await;
    store.bootstrap_deployment(alice).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;
    let (bob_access, _bob_ticket, bob) = user_ticket(&store, "bob").await;
    let object = place_note(&state, channel, &bob_access).await;
    let until = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
        + 60_000;
    store
        .set_member_timeout(bob, until, Some("cool off"), alice)
        .await
        .unwrap();

    for method in ["PUT", "DELETE"] {
        let request = lock_request(method, channel, &bob_access, &object);
        assert_eq!(
            status_of(&state, request).await,
            StatusCode::FORBIDDEN,
            "{method}"
        );
    }
    let edit = post_json(
        &format!("/channels/{channel}/canvas/ops"),
        &bob_access,
        json!({
            "id": Uuid::now_v7().to_string(), "kind": "edit", "object_id": object,
            "props": { "text": "changed", "color": "annotation" },
        }),
    );
    assert_eq!(status_of(&state, edit).await, StatusCode::FORBIDDEN);
    let _ = alice_access;
}

/// A lock outlives the erase that hid its object, and the lock list leaves
/// erased objects out, so an undo has to say which restored objects are locked.
#[tokio::test]
async fn restoring_a_locked_object_publishes_its_lock() {
    let (store, _guard) = new_store().await;
    let state = support::app::state(store.clone());
    let (alice_access, alice_ticket, alice) = user_ticket(&store, "alice").await;
    store.bootstrap_deployment(alice).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;
    let (_bob_access, bob_ticket, _bob) = user_ticket(&store, "bob").await;
    let addr = serve(state.clone()).await;
    let _alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;
    let object = place_note(&state, channel, &alice_access).await;
    let request = lock_request("PUT", channel, &alice_access, &object);
    assert_eq!(status_of(&state, request).await, StatusCode::NO_CONTENT);

    // Only the locked note is left, so this clear takes it (decision 0085).
    let cleared = http::router(state.clone())
        .oneshot(crate::requests::clear_request(channel, &alice_access, 1))
        .await
        .unwrap();
    let bytes = axum::body::to_bytes(cleared.into_body(), usize::MAX)
        .await
        .unwrap();
    let cleared: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(cleared["op"]["affected"], 1, "{cleared}");
    let op = cleared["op"]["id"].as_str().unwrap().to_owned();
    let restore = crate::requests::restore_request(channel, &alice_access, &op);
    assert_eq!(status_of(&state, restore).await, StatusCode::CREATED);

    let mut types = Vec::new();
    for _ in 0..5 {
        types.push(
            read_frame(&mut bob_ws).await["type"]
                .as_str()
                .unwrap()
                .to_owned(),
        );
    }
    assert_eq!(
        types,
        [
            "canvas.object.placed",
            "canvas.object.lock_changed",
            "canvas.cleared",
            "canvas.objects.restored",
            "canvas.object.lock_changed",
        ]
    );
}
