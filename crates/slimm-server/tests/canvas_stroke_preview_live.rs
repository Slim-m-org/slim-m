// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Live in-flight stroke preview: the same two-bit authorization and
//! appear-offline guard [`canvas_cursor_live`] already covers, plus what is
//! new to a frame that carries drawing content rather than a bare position -
//! a bound on how much one frame may carry, a direct timeout check, and a
//! byte-rate limiter rather than a per-request one.
//!
//! [`canvas_cursor_live`]: ../tests/canvas_cursor_live.rs

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

async fn send_preview(
    ws: &mut Client,
    channel_id: &str,
    object_id: &str,
    points: &[f64],
    ended: bool,
) {
    ws.send(WsMessage::Text(
        json!({
            "type": "canvas.stroke_preview",
            "channel_id": channel_id,
            "object_id": object_id,
            "points": points,
            "ended": ended,
        })
        .to_string(),
    ))
    .await
    .unwrap();
}

fn new_object_id() -> String {
    uuid::Uuid::now_v7().to_string()
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
}

/// The load-bearing pair: a viewer holding both bits receives the frame, with
/// every field carried through, and a viewer denied `USE_CANVAS`
/// specifically receives nothing even though `VIEW_CHANNEL` alone would pass
/// a plain channel-scoped check. Mirrors `canvas_cursor_live.rs`'s own pair.
#[tokio::test]
async fn a_viewer_with_both_bits_receives_the_preview() {
    let (store, _guard) = support::new_store("slimm-canvas-stroke-preview-live").await;
    let (alice_ticket, alice_id) = user_ticket_and_id(&store, "alice").await;
    store.bootstrap_deployment(alice_id).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;
    let (bob_ticket, _bob_id) = user_ticket_and_id(&store, "bob").await;
    let object_id = new_object_id();

    let state = support::app::builder(store.clone()).hub(Hub::new()).build();
    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    send_preview(
        &mut alice_ws,
        &channel.to_string(),
        &object_id,
        &[1.0, 2.0, 3.0, 4.0],
        false,
    )
    .await;

    let frame = next_of_type(&mut bob_ws, "canvas.stroke_preview.updated").await;
    assert_eq!(frame["channel_id"], channel.to_string());
    assert_eq!(frame["user_id"], alice_id.to_string());
    assert_eq!(frame["object_id"], object_id);
    assert_eq!(frame["points"], json!([1.0, 2.0, 3.0, 4.0]));
    assert_eq!(frame["ended"], false);
}

#[tokio::test]
async fn a_member_denied_use_canvas_never_sees_a_preview() {
    let (store, _guard) = support::new_store("slimm-canvas-stroke-preview-live").await;
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
        &channel.to_string(),
        &new_object_id(),
        &[1.0, 1.0],
        false,
    )
    .await;

    assert_nothing_of_type(&mut carol_ws, "canvas.stroke_preview.updated").await;
}

/// Hiding presence does not hide live ink from people who can view the
/// same canvas: they already see the committed result, and withholding the
/// live frames made every hidden drawer's work appear only when finished.
#[tokio::test]
async fn a_hidden_users_preview_reaches_a_viewer_of_the_same_canvas() {
    use slimm_server::presence::Visibility;
    let (store, _guard) = support::new_store("slimm-canvas-stroke-preview-live").await;
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
        &channel.to_string(),
        &new_object_id(),
        &[1.0, 1.0],
        false,
    )
    .await;

    let frame = next_of_type(&mut bob_ws, "canvas.stroke_preview.updated").await;
    assert_eq!(frame["user_id"], alice_id.to_string());
}

/// A point outside the bounded world (or non-finite) is dropped outright,
/// never relayed, the same treatment `canvas.cursor` already gets.
#[tokio::test]
async fn an_out_of_bounds_point_is_dropped() {
    let (store, _guard) = support::new_store("slimm-canvas-stroke-preview-live").await;
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
        &channel.to_string(),
        &new_object_id(),
        &[50_000_000.0, 0.0],
        false,
    )
    .await;

    assert_nothing_of_type(&mut bob_ws, "canvas.stroke_preview.updated").await;
}

/// A frame carrying more coordinate pairs than one preview may ever hold is
/// dropped outright - it is not something a well-behaved client's own
/// throttle could have produced, so there is nothing to salvage by keeping
/// the first N pairs and relaying the rest.
#[tokio::test]
async fn a_frame_carrying_too_many_points_is_dropped() {
    let (store, _guard) = support::new_store("slimm-canvas-stroke-preview-live").await;
    let (alice_ticket, alice_id) = user_ticket_and_id(&store, "alice").await;
    store.bootstrap_deployment(alice_id).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;
    let (bob_ticket, _bob_id) = user_ticket_and_id(&store, "bob").await;

    let state = support::app::builder(store.clone()).hub(Hub::new()).build();
    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    let too_many: Vec<f64> = (0..(25 * 2)).map(|i| i as f64).collect();
    send_preview(
        &mut alice_ws,
        &channel.to_string(),
        &new_object_id(),
        &too_many,
        false,
    )
    .await;

    assert_nothing_of_type(&mut bob_ws, "canvas.stroke_preview.updated").await;
}

/// The bit a timeout cannot express reaches this path too. `TIMEOUT_DENY`
/// spares `USE_CANVAS` because that one bit means view *and* draw, so
/// without a direct check here a timed-out member could keep drawing over
/// the socket even though `POST .../canvas/objects` already refuses them.
#[tokio::test]
async fn a_timed_out_member_cannot_send_a_preview() {
    let (store, _guard) = support::new_store("slimm-canvas-stroke-preview-live").await;
    let (alice_ticket, alice_id) = user_ticket_and_id(&store, "alice").await;
    store.bootstrap_deployment(alice_id).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;
    let (bob_ticket, bob_id) = user_ticket_and_id(&store, "bob").await;

    let until = now_ms() + 60_000;
    store
        .set_member_timeout(bob_id, until, Some("cool off"), alice_id)
        .await
        .unwrap();

    let state = support::app::builder(store.clone()).hub(Hub::new()).build();
    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    send_preview(
        &mut bob_ws,
        &channel.to_string(),
        &new_object_id(),
        &[1.0, 1.0],
        false,
    )
    .await;

    assert_nothing_of_type(&mut alice_ws, "canvas.stroke_preview.updated").await;
}

/// Preview frames are rate limited by the bytes they carry, not by count: a
/// tight loop of frames near the per-frame point ceiling still gets capped.
#[tokio::test]
async fn preview_frames_are_rate_limited_by_bytes() {
    let (store, _guard) = support::new_store("slimm-canvas-stroke-preview-live").await;
    let (alice_ticket, alice_id) = user_ticket_and_id(&store, "alice").await;
    store.bootstrap_deployment(alice_id).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;
    let (bob_ticket, _bob_id) = user_ticket_and_id(&store, "bob").await;

    let state = support::app::builder(store.clone()).hub(Hub::new()).build();
    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    let object_id = new_object_id();
    let points: Vec<f64> = (0..48).map(|i| i as f64 + 0.123_456).collect();
    let total = 40;
    for _ in 0..total {
        send_preview(
            &mut alice_ws,
            &channel.to_string(),
            &object_id,
            &points,
            false,
        )
        .await;
    }

    let mut seen = 0usize;
    loop {
        let next = tokio::time::timeout(Duration::from_millis(500), read_frame(&mut bob_ws)).await;
        match next {
            Ok(frame) if frame["type"] == "canvas.stroke_preview.updated" => seen += 1,
            Ok(_) => {}
            Err(_) => break,
        }
    }

    assert!(seen >= 1, "at least the burst-allowed frames get through");
    assert!(
        seen < total,
        "the byte-rate limiter must refuse some of {total} large rapid frames, only {seen} got through",
    );
}

/// An odd coordinate list would index past its end in a receiver's painter, so
/// it is dropped. A valid frame sent right after proves the odd one was
/// refused, not merely slow: frames arrive in order.
#[tokio::test]
async fn an_odd_length_point_list_is_dropped_before_the_next_frame_arrives() {
    let (store, _guard) = support::new_store("slimm-canvas-stroke-preview-live").await;
    let (alice_ticket, alice_id) = user_ticket_and_id(&store, "alice").await;
    store.bootstrap_deployment(alice_id).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;
    let (bob_ticket, _bob_id) = user_ticket_and_id(&store, "bob").await;

    let state = support::app::builder(store.clone()).hub(Hub::new()).build();
    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    let odd = new_object_id();
    let sentinel = new_object_id();
    send_preview(
        &mut alice_ws,
        &channel.to_string(),
        &odd,
        &[1.0, 2.0, 3.0],
        false,
    )
    .await;
    send_preview(
        &mut alice_ws,
        &channel.to_string(),
        &sentinel,
        &[1.0, 2.0],
        false,
    )
    .await;

    let first = next_of_type(&mut bob_ws, "canvas.stroke_preview.updated").await;
    assert_eq!(first["object_id"], sentinel, "the odd list was relayed");
}

/// The drawer's pen colour and width travel with the preview, and a forged
/// value never reaches a viewer.
#[tokio::test]
async fn a_preview_carries_the_pen_colour_and_width_and_drops_bad_ones() {
    let (store, _guard) = support::new_store("slimm-canvas-stroke-preview-pen").await;
    let (alice_ticket, alice_id) = user_ticket_and_id(&store, "alice").await;
    store.bootstrap_deployment(alice_id).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;
    let (bob_ticket, _bob_id) = user_ticket_and_id(&store, "bob").await;

    let state = support::app::builder(store.clone()).hub(Hub::new()).build();
    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    for (color, width) in [
        (json!("annotation"), json!(6.5)),
        (json!("a b!"), json!(1e9)),
    ] {
        alice_ws
            .send(WsMessage::Text(
                json!({
                    "type": "canvas.stroke_preview",
                    "channel_id": channel.to_string(),
                    "object_id": new_object_id(),
                    "points": [1.0, 2.0],
                    "color": color,
                    "width": width,
                })
                .to_string(),
            ))
            .await
            .unwrap();
        let frame = next_of_type(&mut bob_ws, "canvas.stroke_preview.updated").await;
        if color == json!("annotation") {
            assert_eq!(frame["color"], "annotation");
            assert_eq!(frame["width"], 6.5);
        } else {
            assert!(frame["color"].is_null(), "forged colour was relayed");
            assert!(frame["width"].is_null(), "forged width was relayed");
        }
    }
}

#[tokio::test]
async fn a_cancelled_stroke_preview_relays_with_cancelled_true() {
    let (store, _guard) = support::new_store("slimm-canvas-stroke-preview-cancel").await;
    let (alice_ticket, alice_id) = user_ticket_and_id(&store, "alice").await;
    store.bootstrap_deployment(alice_id).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;
    let (bob_ticket, _bob_id) = user_ticket_and_id(&store, "bob").await;

    let state = support::app::builder(store.clone()).hub(Hub::new()).build();
    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    let object_id = new_object_id();
    alice_ws
        .send(WsMessage::Text(
            json!({
                "type": "canvas.stroke_preview",
                "channel_id": channel.to_string(),
                "object_id": object_id,
                "points": [],
                "ended": true,
                "cancelled": true,
            })
            .to_string(),
        ))
        .await
        .unwrap();

    let frame = next_of_type(&mut bob_ws, "canvas.stroke_preview.updated").await;
    assert_eq!(frame["object_id"], object_id);
    assert_eq!(frame["ended"], true);
    assert_eq!(frame["cancelled"], true);
}
