// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Live tile-drag preview relay: gated like the committed slot write, so a locked tile, a member without canvas access and a timed-out member stream nothing.

use std::time::Duration;

use futures_util::SinkExt;
use serde_json::{Value, json};
use slimm_server::hub::Hub;
use slimm_server::ids::{ChannelId, UserId};
use slimm_server::permissions::Permissions;
use slimm_server::store::MediaSlotKind;
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

async fn send_preview(ws: &mut Client, channel: ChannelId, owner: UserId, x: f64) {
    ws.send(WsMessage::Text(
        json!({
            "type": "canvas.media_slot_preview", "channel_id": channel.to_string(),
            "kind": "camera", "user_id": owner.to_string(),
            "x": x, "y": 10.0, "w": 220.0, "h": 160.0,
        })
        .to_string(),
    ))
    .await
    .unwrap();
}

const KIND: &str = "canvas.media_slot_preview.updated";

#[tokio::test]
async fn a_viewer_receives_a_streamed_tile_drag() {
    let (store, _guard) = support::new_store("slimm-media-slot-preview").await;
    let (alice_ticket, alice_id) = user_ticket_and_id(&store, "alice").await;
    store.bootstrap_deployment(alice_id).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;
    let (bob_ticket, bob_id) = user_ticket_and_id(&store, "bob").await;

    let state = support::app::builder(store.clone()).hub(Hub::new()).build();
    let addr = serve(state).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    send_preview(&mut alice_ws, channel, bob_id, 42.5).await;

    let frame = next_of_type(&mut bob_ws, KIND).await;
    assert_eq!(frame["user_id"], alice_id.to_string());
    assert_eq!(frame["slot_user_id"], bob_id.to_string());
    assert_eq!(frame["kind"], "camera");
    assert_eq!(frame["x"], 42.5);
    assert_eq!(frame["ended"], false);
}

#[tokio::test]
async fn a_locked_tile_streams_nothing() {
    let (store, _guard) = support::new_store("slimm-media-slot-preview").await;
    let (alice_ticket, alice_id) = user_ticket_and_id(&store, "alice").await;
    store.bootstrap_deployment(alice_id).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;
    let (bob_ticket, bob_id) = user_ticket_and_id(&store, "bob").await;
    store
        .upsert_canvas_media_slot(
            channel,
            bob_id,
            MediaSlotKind::Camera,
            (0.0, 0.0, 220.0, 160.0),
            true,
            false,
        )
        .await
        .unwrap();

    let state = support::app::builder(store.clone()).hub(Hub::new()).build();
    let addr = serve(state).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    send_preview(&mut alice_ws, channel, bob_id, 42.5).await;

    assert_nothing_of_type(&mut bob_ws, KIND).await;
}

#[tokio::test]
async fn a_member_denied_use_canvas_neither_sends_nor_receives() {
    let (store, _guard) = support::new_store("slimm-media-slot-preview").await;
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
    let addr = serve(state).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut carol_ws = connect(addr, &carol_ticket).await;

    send_preview(&mut alice_ws, channel, alice_id, 1.0).await;
    assert_nothing_of_type(&mut carol_ws, KIND).await;
    // The sender hears its own frame; drained so only carol's could follow.
    next_of_type(&mut alice_ws, KIND).await;

    send_preview(&mut carol_ws, channel, alice_id, 2.0).await;
    assert_nothing_of_type(&mut alice_ws, KIND).await;
}

#[tokio::test]
async fn an_out_of_bounds_box_is_dropped() {
    let (store, _guard) = support::new_store("slimm-media-slot-preview").await;
    let (alice_ticket, alice_id) = user_ticket_and_id(&store, "alice").await;
    store.bootstrap_deployment(alice_id).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;
    let (bob_ticket, bob_id) = user_ticket_and_id(&store, "bob").await;

    let state = support::app::builder(store.clone()).hub(Hub::new()).build();
    let addr = serve(state).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    send_preview(&mut alice_ws, channel, bob_id, 50_000_000.0).await;

    assert_nothing_of_type(&mut bob_ws, KIND).await;
}

#[tokio::test]
async fn a_timed_out_member_cannot_stream_a_tile() {
    let (store, _guard) = support::new_store("slimm-media-slot-preview").await;
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
    let addr = serve(state).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    send_preview(&mut bob_ws, channel, bob_id, 1.0).await;

    assert_nothing_of_type(&mut alice_ws, KIND).await;
}

#[tokio::test]
async fn tile_preview_frames_are_rate_limited() {
    let (store, _guard) = support::new_store("slimm-media-slot-preview").await;
    let (alice_ticket, alice_id) = user_ticket_and_id(&store, "alice").await;
    store.bootstrap_deployment(alice_id).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;
    let (bob_ticket, bob_id) = user_ticket_and_id(&store, "bob").await;

    let state = support::app::builder(store.clone()).hub(Hub::new()).build();
    let addr = serve(state).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    for i in 0..120 {
        send_preview(&mut alice_ws, channel, bob_id, f64::from(i)).await;
    }

    let mut seen = 0usize;
    while let Ok(frame) =
        tokio::time::timeout(Duration::from_millis(500), read_frame(&mut bob_ws)).await
    {
        if frame["type"] == KIND {
            seen += 1;
        }
    }
    assert!(seen >= 1, "the burst allowance gets through");
    assert!(seen < 120, "the limiter refused none of 120 rapid frames");
}
