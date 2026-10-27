// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Live view-rectangle relay for follow and "bring everyone to me": the
//! authorization, bounds check and rate limit a cursor gets.

use std::time::Duration;

use futures_util::SinkExt;
use serde_json::{Value, json};
use slimm_server::hub::Hub;
use slimm_server::permissions::Permissions;
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

async fn send_view(ws: &mut Client, channel_id: &str, rect: [f64; 4], summon: bool) {
    ws.send(WsMessage::Text(
        json!({
            "type": "canvas.view", "channel_id": channel_id,
            "x": rect[0], "y": rect[1], "w": rect[2], "h": rect[3], "summon": summon,
        })
        .to_string(),
    ))
    .await
    .unwrap();
}

const VIEW: &str = "canvas.view.updated";

#[tokio::test]
async fn a_viewer_with_both_bits_receives_the_view_and_the_summon_flag() {
    let (store, _guard) = support::new_store("slimm-canvas-view-live").await;
    let (alice_ticket, alice_id) = user_ticket_and_id(&store, "alice").await;
    store.bootstrap_deployment(alice_id).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;
    let (bob_ticket, _bob_id) = user_ticket_and_id(&store, "bob").await;

    let state = support::app::builder(store.clone()).hub(Hub::new()).build();
    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    send_view(
        &mut alice_ws,
        &channel.to_string(),
        [10.0, 20.0, 960.0, 540.0],
        true,
    )
    .await;

    let frame = next_of_type(&mut bob_ws, VIEW).await;
    assert_eq!(frame["channel_id"], channel.to_string());
    assert_eq!(frame["user_id"], alice_id.to_string());
    assert_eq!(frame["x"], 10.0);
    assert_eq!(frame["w"], 960.0);
    assert_eq!(frame["summon"], true);

    send_view(
        &mut alice_ws,
        &channel.to_string(),
        [0.0, 0.0, 1920.0, 1080.0],
        false,
    )
    .await;
    let frame = next_of_type(&mut bob_ws, VIEW).await;
    assert_eq!(frame["summon"], false);
}

#[tokio::test]
async fn a_member_denied_use_canvas_never_sees_a_view() {
    let (store, _guard) = support::new_store("slimm-canvas-view-live").await;
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

    send_view(
        &mut alice_ws,
        &channel.to_string(),
        [0.0, 0.0, 100.0, 100.0],
        false,
    )
    .await;

    assert_nothing_of_type(&mut carol_ws, VIEW).await;
}

#[tokio::test]
async fn an_out_of_bounds_or_empty_view_is_dropped() {
    let (store, _guard) = support::new_store("slimm-canvas-view-live").await;
    let (alice_ticket, alice_id) = user_ticket_and_id(&store, "alice").await;
    store.bootstrap_deployment(alice_id).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id.to_string();
    let (bob_ticket, _bob_id) = user_ticket_and_id(&store, "bob").await;

    let state = support::app::builder(store.clone()).hub(Hub::new()).build();
    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    send_view(
        &mut alice_ws,
        &channel,
        [50_000_000.0, 0.0, 10.0, 10.0],
        false,
    )
    .await;
    send_view(&mut alice_ws, &channel, [0.0, 0.0, 0.0, 10.0], false).await;
    send_view(&mut alice_ws, &channel, [0.0, 0.0, -5.0, 10.0], false).await;

    assert_nothing_of_type(&mut bob_ws, VIEW).await;
}

#[tokio::test]
async fn view_frames_are_rate_limited() {
    let (store, _guard) = support::new_store("slimm-canvas-view-live").await;
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
            .create_channel(&format!("canvas-view-rl-{i}"), "text")
            .await
            .unwrap();
        channel_ids.push(channel.id.to_string());
    }
    for channel_id in &channel_ids {
        send_view(&mut alice_ws, channel_id, [0.0, 0.0, 10.0, 10.0], false).await;
    }

    let mut seen = 0usize;
    loop {
        let next = tokio::time::timeout(Duration::from_millis(500), read_frame(&mut bob_ws)).await;
        match next {
            Ok(frame) if frame["type"] == VIEW => seen += 1,
            Ok(_) => {}
            Err(_) => break,
        }
    }
    assert!(seen >= 1, "at least the burst-allowed frames get through");
    assert!(
        seen < channel_ids.len(),
        "the limiter must refuse some of {} rapid frames, only {seen} got through",
        channel_ids.len()
    );
}

#[tokio::test]
async fn a_full_screen_tile_key_rides_the_view_and_an_oversized_one_is_dropped() {
    let (store, _guard) = support::new_store("slimm-canvas-view-live").await;
    let (alice_ticket, alice_id) = user_ticket_and_id(&store, "alice").await;
    store.bootstrap_deployment(alice_id).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id.to_string();
    let (bob_ticket, _bob_id) = user_ticket_and_id(&store, "bob").await;

    let state = support::app::builder(store.clone()).hub(Hub::new()).build();
    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    for (tile, expected) in [
        (json!("screen:abc"), json!("screen:abc")),
        (json!("x".repeat(200)), serde_json::Value::Null),
    ] {
        alice_ws
            .send(WsMessage::Text(
                json!({
                    "type": "canvas.view", "channel_id": channel,
                    "x": 0.0, "y": 0.0, "w": 100.0, "h": 100.0, "tile": tile,
                })
                .to_string(),
            ))
            .await
            .unwrap();
        let frame = next_of_type(&mut bob_ws, VIEW).await;
        assert_eq!(frame["tile"], expected);
    }
}
