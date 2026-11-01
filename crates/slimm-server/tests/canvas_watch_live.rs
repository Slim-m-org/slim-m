// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Live canvas frames go only to sockets that can draw them: never back to the
//! sender, and not to a connection that declared a different set of canvases.

use std::time::Duration;

use futures_util::SinkExt;
use serde_json::{Value, json};
use slimm_server::hub::Hub;
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

async fn send(ws: &mut Client, frame: Value) {
    ws.send(WsMessage::Text(frame.to_string())).await.unwrap();
}

/// A pong proves the server has handled every frame sent before the ping.
async fn settle(ws: &mut Client) {
    send(ws, json!({ "type": "ping" })).await;
    next_of_type(ws, "pong").await;
}

async fn watch(ws: &mut Client, channel_ids: &[String]) {
    send(
        ws,
        json!({ "type": "canvas.watch", "channel_ids": channel_ids }),
    )
    .await;
    settle(ws).await;
}

struct Room {
    alice: Client,
    bob: Client,
    channel: String,
    other: String,
}

async fn room() -> (Room, support::TestDbGuard) {
    let (store, guard) = support::new_store("slimm-canvas-watch").await;
    let (alice_ticket, alice_id) = user_ticket_and_id(&store, "alice").await;
    store.bootstrap_deployment(alice_id).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id.to_string();
    let other = store
        .create_channel("second-canvas", "text")
        .await
        .unwrap()
        .id
        .to_string();
    let (bob_ticket, _) = user_ticket_and_id(&store, "bob").await;
    let state = support::app::builder(store).hub(Hub::new()).build();
    let addr = serve(state).await;
    let alice = connect(addr, &alice_ticket).await;
    let bob = connect(addr, &bob_ticket).await;
    let room = Room {
        alice,
        bob,
        channel,
        other,
    };
    (room, guard)
}

async fn cursor(ws: &mut Client, channel: &str) {
    send(
        ws,
        json!({ "type": "canvas.cursor", "channel_id": channel, "x": 1.0, "y": 2.0 }),
    )
    .await;
}

#[tokio::test]
async fn a_cursor_is_not_echoed_to_its_sender() {
    let (mut room, _guard) = room().await;
    cursor(&mut room.alice, &room.channel).await;
    next_of_type(&mut room.bob, "canvas.cursor.moved").await;
    assert_nothing_of_type(&mut room.alice, "canvas.cursor.moved").await;
}

#[tokio::test]
async fn a_connection_watching_another_canvas_gets_no_cursor() {
    let (mut room, _guard) = room().await;
    watch(&mut room.bob, std::slice::from_ref(&room.other)).await;
    cursor(&mut room.alice, &room.channel).await;
    assert_nothing_of_type(&mut room.bob, "canvas.cursor.moved").await;
}

#[tokio::test]
async fn a_connection_watching_the_canvas_gets_its_cursor() {
    let (mut room, _guard) = room().await;
    watch(&mut room.bob, std::slice::from_ref(&room.channel)).await;
    cursor(&mut room.alice, &room.channel).await;
    next_of_type(&mut room.bob, "canvas.cursor.moved").await;
}

#[tokio::test]
async fn an_empty_watch_silences_every_canvas() {
    let (mut room, _guard) = room().await;
    watch(&mut room.bob, &[]).await;
    cursor(&mut room.alice, &room.channel).await;
    assert_nothing_of_type(&mut room.bob, "canvas.cursor.moved").await;
}

#[tokio::test]
async fn a_stroke_preview_follows_the_same_rule() {
    let (mut room, _guard) = room().await;
    let preview = json!({
        "type": "canvas.stroke_preview", "channel_id": room.channel,
        "object_id": uuid::Uuid::now_v7().to_string(), "points": [0.0, 0.0],
    });
    watch(&mut room.bob, std::slice::from_ref(&room.other)).await;
    send(&mut room.alice, preview.clone()).await;
    assert_nothing_of_type(&mut room.bob, "canvas.stroke_preview.updated").await;
    watch(&mut room.bob, std::slice::from_ref(&room.channel)).await;
    send(&mut room.alice, preview).await;
    next_of_type(&mut room.bob, "canvas.stroke_preview.updated").await;
}
