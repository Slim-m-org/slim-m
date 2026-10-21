// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Live drag and resize preview relay: the same two-bit authorization, the
//! appear-offline guard, the bounds check and the rate limit a cursor gets.

use std::time::Duration;

use futures_util::SinkExt;
use serde_json::{Value, json};
use slimm_server::hub::Hub;
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use tokio_tungstenite::tungstenite::Message as WsMessage;

mod support;

use support::ws::{Client, connect, read_frame, serve, user_ticket_and_id};

async fn next_of_type(ws: &mut Client, frame_type: &str) -> Value {
    let outcome = tokio::time::timeout(Duration::from_secs(2), async {
        loop {
            let frame = read_frame(ws).await;
            if frame["type"] == frame_type {
                return frame;
            }
        }
    })
    .await;
    outcome.unwrap_or_else(|_| panic!("no {frame_type} arrived in time"))
}

async fn assert_nothing_of_type(ws: &mut Client, frame_type: &str) {
    let outcome =
        tokio::time::timeout(Duration::from_millis(300), next_of_type(ws, frame_type)).await;
    assert!(outcome.is_err(), "unexpected {frame_type}");
}

/// Previews a fresh note of `author`'s, since a preview of an object nobody holds is dropped.
async fn send_preview(
    ws: &mut Client,
    store: &Store,
    author: slimm_server::ids::UserId,
    channel_id: &str,
    x: f64,
    y: f64,
) {
    let object = slimm_server::ids::CanvasObjectId::generate();
    let channel = slimm_server::ids::ChannelId(channel_id.parse().unwrap());
    let request = slimm_server::store::PlaceRequest {
        kind: "note",
        bounds: (0.0, 0.0, 40.0, 20.0),
        props: "{}",
        attachment: None,
    };
    store
        .place_canvas_object(channel, author, object, request)
        .await
        .unwrap();
    let object_id = object.to_string();
    ws.send(WsMessage::Text(
        json!({
            "type": "canvas.object_preview", "channel_id": channel_id,
            "object_id": object_id, "x": x, "y": y, "w": 40.0, "h": 20.0,
        })
        .to_string(),
    ))
    .await
    .unwrap();
}

/// The load-bearing pair: a viewer holding both bits receives the frame, and
/// a viewer denied `USE_CANVAS` specifically (below) receives nothing, even
/// though `VIEW_CHANNEL` alone would already pass a plain channel-scoped
/// check. Mirrors `canvas_live.rs`'s placement test for the same reason: a
/// cache or a gate that only remembers the view bit would deliver here.
#[tokio::test]
async fn a_viewer_with_both_bits_receives_the_preview() {
    let (store, _guard) = support::new_store("slimm-canvas-object-preview-live").await;
    let (alice_ticket, alice_id) = user_ticket_and_id(&store, "alice").await;
    store.bootstrap_deployment(alice_id).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;
    let (bob_ticket, _bob_id) = user_ticket_and_id(&store, "bob").await;

    let state = support::app::builder(store.clone()).hub(Hub::new()).build();
    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    send_preview(
        &mut alice_ws,
        &store,
        alice_id,
        &channel.to_string(),
        12.5,
        -4.0,
    )
    .await;

    let frame = next_of_type(&mut bob_ws, "canvas.object_preview.updated").await;
    assert_eq!(frame["channel_id"], channel.to_string());
    assert_eq!(frame["user_id"], alice_id.to_string());
    assert_eq!(frame["x"], 12.5);
    assert_eq!(frame["y"], -4.0);
    assert_eq!(frame["w"], 40.0);
    assert_eq!(frame["ended"], false);
}

#[tokio::test]
async fn a_member_denied_use_canvas_never_sees_a_preview() {
    let (store, _guard) = support::new_store("slimm-canvas-object-preview-live").await;
    let (alice_ticket, alice_id) = user_ticket_and_id(&store, "alice").await;
    store.bootstrap_deployment(alice_id).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;

    let (carol_ticket, carol_id) = user_ticket_and_id(&store, "carol").await;
    store
        .set_member_overwrite(
            channel,
            carol_id,
            Permissions::NONE,
            Permissions::USE_CANVAS,
        )
        .await
        .unwrap();

    let state = support::app::builder(store.clone()).hub(Hub::new()).build();
    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut carol_ws = connect(addr, &carol_ticket).await;

    send_preview(
        &mut alice_ws,
        &store,
        alice_id,
        &channel.to_string(),
        12.5,
        -4.0,
    )
    .await;

    assert_nothing_of_type(&mut carol_ws, "canvas.object_preview.updated").await;
}

/// Hiding presence does not hide live ink from people who can view the
/// same canvas: they already see the committed result, and withholding the
/// live frames made every hidden drawer's work appear only when finished.
#[tokio::test]
async fn a_hidden_users_preview_reaches_a_viewer_of_the_same_canvas() {
    use slimm_server::presence::Visibility;
    let (store, _guard) = support::new_store("slimm-canvas-object-preview-live").await;
    let (alice_ticket, alice_id) = user_ticket_and_id(&store, "alice").await;
    store.bootstrap_deployment(alice_id).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;
    store
        .set_presence_visibility(alice_id, Visibility::Hidden)
        .await
        .unwrap();
    let (bob_ticket, _bob_id) = user_ticket_and_id(&store, "bob").await;

    let state = support::app::builder(store.clone()).hub(Hub::new()).build();
    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    send_preview(
        &mut alice_ws,
        &store,
        alice_id,
        &channel.to_string(),
        1.0,
        1.0,
    )
    .await;

    let frame = next_of_type(&mut bob_ws, "canvas.object_preview.updated").await;
    assert_eq!(frame["user_id"], alice_id.to_string());
}

/// A position outside the bounded world (or non-finite) is dropped outright,
/// never relayed: nothing downstream clamps it, so a receiver's paint layer
/// would otherwise have to defend against a coordinate it can never trust.
#[tokio::test]
async fn an_out_of_bounds_preview_is_dropped() {
    let (store, _guard) = support::new_store("slimm-canvas-object-preview-live").await;
    let (alice_ticket, alice_id) = user_ticket_and_id(&store, "alice").await;
    store.bootstrap_deployment(alice_id).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;
    let (bob_ticket, _bob_id) = user_ticket_and_id(&store, "bob").await;

    let state = support::app::builder(store.clone()).hub(Hub::new()).build();
    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    send_preview(
        &mut alice_ws,
        &store,
        alice_id,
        &channel.to_string(),
        50_000_000.0,
        0.0,
    )
    .await;

    assert_nothing_of_type(&mut bob_ws, "canvas.object_preview.updated").await;
}

/// Cursor frames are rate limited independently of the channel: a tight loop
/// across enough distinct channels that every send would otherwise be a
/// fresh frame still caps how many actually fan out.
#[tokio::test]
async fn object_preview_frames_are_rate_limited() {
    let (store, _guard) = support::new_store("slimm-canvas-object-preview-live").await;
    let (alice_ticket, alice_id) = user_ticket_and_id(&store, "alice").await;
    store.bootstrap_deployment(alice_id).await.unwrap();
    let (bob_ticket, _bob_id) = user_ticket_and_id(&store, "bob").await;

    let state = support::app::builder(store.clone()).hub(Hub::new()).build();
    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    let mut channel_ids = Vec::new();
    for i in 0..60 {
        let channel = store
            .create_channel(&format!("canvas-object-preview-rl-{i}"), "text")
            .await
            .unwrap();
        channel_ids.push(channel.id.to_string());
    }

    for channel_id in &channel_ids {
        send_preview(&mut alice_ws, &store, alice_id, channel_id, 1.0, 1.0).await;
    }

    let mut seen = 0usize;
    loop {
        let next = tokio::time::timeout(Duration::from_millis(500), read_frame(&mut bob_ws)).await;
        match next {
            Ok(frame) if frame["type"] == "canvas.object_preview.updated" => seen += 1,
            Ok(_) => {}
            Err(_) => break,
        }
    }

    assert!(seen >= 1, "at least the burst-allowed frames get through");
    assert!(
        seen < channel_ids.len(),
        "the rate limiter must refuse some of {} rapid frames, only {seen} got through",
        channel_ids.len()
    );
}

/// A preview shows a member moving content, so a timed-out member may not
/// send one even though a cursor is allowed.
#[tokio::test]
async fn a_timed_out_member_cannot_send_a_preview() {
    let (store, _guard) = support::new_store("slimm-canvas-object-preview-live").await;
    let (alice_ticket, alice_id) = user_ticket_and_id(&store, "alice").await;
    store.bootstrap_deployment(alice_id).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;
    let (bob_ticket, bob_id) = user_ticket_and_id(&store, "bob").await;

    let until = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
        + 60_000;
    store
        .set_member_timeout(bob_id, until, Some("cool off"), alice_id)
        .await
        .unwrap();

    let state = support::app::builder(store.clone()).hub(Hub::new()).build();
    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    send_preview(&mut bob_ws, &store, bob_id, &channel.to_string(), 1.0, 1.0).await;

    assert_nothing_of_type(&mut alice_ws, "canvas.object_preview.updated").await;
}

/// A preview box wider than any committed object can be is dropped: a
/// receiver rasterises it into its spatial grid, so a world-sized box would
/// freeze every viewer.
#[tokio::test]
async fn an_oversize_preview_box_is_dropped() {
    let (store, _guard) = support::new_store("slimm-canvas-object-preview-live").await;
    let (alice_ticket, alice_id) = user_ticket_and_id(&store, "alice").await;
    store.bootstrap_deployment(alice_id).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;
    let (bob_ticket, _bob_id) = user_ticket_and_id(&store, "bob").await;

    let state = support::app::builder(store.clone()).hub(Hub::new()).build();
    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    let object = slimm_server::ids::CanvasObjectId::generate();
    let request = slimm_server::store::PlaceRequest {
        kind: "note",
        bounds: (0.0, 0.0, 40.0, 20.0),
        props: "{}",
        attachment: None,
    };
    store
        .place_canvas_object(channel, alice_id, object, request)
        .await
        .unwrap();
    let object_id = object.to_string();
    alice_ws
        .send(WsMessage::Text(
            json!({
                "type": "canvas.object_preview", "channel_id": channel.to_string(),
                "object_id": object_id, "x": 0.0, "y": 0.0, "w": 5e6, "h": 5e6,
            })
            .to_string(),
        ))
        .await
        .unwrap();
    // Frames arrive in order, so a valid one after it proves the oversize box was refused.
    send_preview(
        &mut alice_ws,
        &store,
        alice_id,
        &channel.to_string(),
        1.0,
        1.0,
    )
    .await;

    let first = next_of_type(&mut bob_ws, "canvas.object_preview.updated").await;
    assert_eq!(first["w"], 40.0, "the oversize box was relayed: {first}");
}

/// A preview moves content on every screen, so only the object's author (or
/// a canvas manager) may stream one for it; a plain member streaming alice's
/// object id must not reach alice.
#[tokio::test]
async fn a_member_cannot_preview_another_members_object() {
    use slimm_server::ids::CanvasObjectId;
    use slimm_server::store::PlaceRequest;
    let (store, _guard) = support::new_store("slimm-canvas-object-preview-live").await;
    let (alice_ticket, alice_id) = user_ticket_and_id(&store, "alice").await;
    store.bootstrap_deployment(alice_id).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;
    let (bob_ticket, bob_id) = user_ticket_and_id(&store, "bob").await;

    let object_id = CanvasObjectId::generate();
    store
        .place_canvas_object(
            channel,
            alice_id,
            object_id,
            PlaceRequest {
                kind: "note",
                bounds: (0.0, 0.0, 40.0, 20.0),
                props: "{}",
                attachment: None,
            },
        )
        .await
        .unwrap();

    let state = support::app::builder(store.clone()).hub(Hub::new()).build();
    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    bob_ws
        .send(WsMessage::Text(
            json!({
                "type": "canvas.object_preview", "channel_id": channel.to_string(),
                "object_id": object_id.to_string(),
                "x": 9000.0, "y": 9000.0, "w": 1.0, "h": 1.0,
            })
            .to_string(),
        ))
        .await
        .unwrap();
    send_preview(&mut bob_ws, &store, bob_id, &channel.to_string(), 5.0, 5.0).await;

    let first = next_of_type(&mut alice_ws, "canvas.object_preview.updated").await;
    assert_ne!(
        first["object_id"],
        object_id.to_string(),
        "bob's preview of alice's object was relayed"
    );
}

/// A canvas manager may drag anyone's object, so their preview of bob's reaches him.
#[tokio::test]
async fn a_canvas_manager_can_preview_another_members_object() {
    let (store, _guard) = support::new_store("slimm-canvas-object-preview-live").await;
    let (alice_ticket, alice_id) = user_ticket_and_id(&store, "alice").await;
    store.bootstrap_deployment(alice_id).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;
    let (bob_ticket, bob_id) = user_ticket_and_id(&store, "bob").await;
    let theirs = slimm_server::ids::CanvasObjectId::generate();
    let request = slimm_server::store::PlaceRequest {
        kind: "note",
        bounds: (0.0, 0.0, 40.0, 20.0),
        props: "{}",
        attachment: None,
    };
    store
        .place_canvas_object(channel, bob_id, theirs, request)
        .await
        .unwrap();

    let state = support::app::builder(store.clone()).hub(Hub::new()).build();
    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;
    alice_ws
        .send(WsMessage::Text(
            json!({
                "type": "canvas.object_preview", "channel_id": channel.to_string(),
                "object_id": theirs.to_string(),
                "x": 7.0, "y": 7.0, "w": 40.0, "h": 20.0,
            })
            .to_string(),
        ))
        .await
        .unwrap();

    let frame = next_of_type(&mut bob_ws, "canvas.object_preview.updated").await;
    assert_eq!(frame["object_id"], theirs.to_string());
}
