// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Live canvas frames go only to sockets that can draw them: never back to the
//! sender, and not to a connection that declared a different set of canvases.

use futures_util::SinkExt;
use serde_json::{Value, json};
use slimm_server::hub::Hub;
use tokio_tungstenite::tungstenite::Message as WsMessage;

mod support;

use support::ws::{
    Client, assert_no_frame_of_type, connect, read_frame_of_type, serve, settle, user_ticket_and_id,
};

async fn send(ws: &mut Client, frame: Value) {
    ws.send(WsMessage::Text(frame.to_string())).await.unwrap();
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
    read_frame_of_type(&mut room.bob, "canvas.cursor.moved").await;
    assert_no_frame_of_type(&mut room.alice, "canvas.cursor.moved").await;
}

#[tokio::test]
async fn a_connection_watching_another_canvas_gets_no_cursor() {
    let (mut room, _guard) = room().await;
    watch(&mut room.bob, std::slice::from_ref(&room.other)).await;
    cursor(&mut room.alice, &room.channel).await;
    assert_no_frame_of_type(&mut room.bob, "canvas.cursor.moved").await;
}

#[tokio::test]
async fn a_connection_watching_the_canvas_gets_its_cursor() {
    let (mut room, _guard) = room().await;
    watch(&mut room.bob, std::slice::from_ref(&room.channel)).await;
    cursor(&mut room.alice, &room.channel).await;
    read_frame_of_type(&mut room.bob, "canvas.cursor.moved").await;
}

#[tokio::test]
async fn an_empty_watch_silences_every_canvas() {
    let (mut room, _guard) = room().await;
    watch(&mut room.bob, &[]).await;
    cursor(&mut room.alice, &room.channel).await;
    assert_no_frame_of_type(&mut room.bob, "canvas.cursor.moved").await;
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
    assert_no_frame_of_type(&mut room.bob, "canvas.stroke_preview.updated").await;
    watch(&mut room.bob, std::slice::from_ref(&room.channel)).await;
    send(&mut room.alice, preview).await;
    read_frame_of_type(&mut room.bob, "canvas.stroke_preview.updated").await;
}

fn view(channel: &str, summon: bool) -> Value {
    json!({
        "type": "canvas.view", "channel_id": channel,
        "x": 0.0, "y": 0.0, "w": 100.0, "h": 100.0, "summon": summon,
    })
}

#[tokio::test]
async fn a_followed_view_goes_only_to_a_connection_watching_the_canvas() {
    let (mut room, _guard) = room().await;
    watch(&mut room.bob, std::slice::from_ref(&room.other)).await;
    send(&mut room.alice, view(&room.channel, false)).await;
    assert_nothing_of_type(&mut room.bob, "canvas.view.updated").await;
    watch(&mut room.bob, std::slice::from_ref(&room.channel)).await;
    send(&mut room.alice, view(&room.channel, false)).await;
    next_of_type(&mut room.bob, "canvas.view.updated").await;
}

#[tokio::test]
async fn a_summon_reaches_a_connection_with_no_canvas_open() {
    let (mut room, _guard) = room().await;
    watch(&mut room.bob, &[]).await;
    send(&mut room.alice, view(&room.channel, true)).await;
    let frame = next_of_type(&mut room.bob, "canvas.view.updated").await;
    assert_eq!(frame["summon"], true);
}

#[tokio::test]
async fn a_followed_view_is_not_echoed_to_its_sender() {
    let (mut room, _guard) = room().await;
    send(&mut room.alice, view(&room.channel, false)).await;
    next_of_type(&mut room.bob, "canvas.view.updated").await;
    assert_nothing_of_type(&mut room.alice, "canvas.view.updated").await;
}
