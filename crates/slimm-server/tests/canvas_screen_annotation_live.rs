// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Live screen-annotation relay: a viewer's mark reaches the sharer, consent is believed only from the sharer, and the canvas gates still apply.

use std::time::Duration;

use futures_util::SinkExt;
use serde_json::{Value, json};
use slimm_server::hub::Hub;
use slimm_server::ids::{ChannelId, UserId};
use slimm_server::permissions::Permissions;
use tokio_tungstenite::tungstenite::Message as WsMessage;

mod support;

use support::ws::{Client, connect, read_frame, serve, user_ticket_and_id};

const KIND: &str = "canvas.screen_annotation.updated";

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

async fn send(ws: &mut Client, body: Value) {
    ws.send(WsMessage::Text(body.to_string())).await.unwrap();
}

async fn send_stroke(ws: &mut Client, channel: ChannelId, sharer: UserId, points: Value) {
    send(
        ws,
        json!({
            "type": "canvas.screen_annotation", "channel_id": channel.to_string(),
            "target_user_id": sharer.to_string(), "kind": "stroke",
            "annotation_id": uuid::Uuid::now_v7().to_string(),
            "points": points, "color": "red",
        }),
    )
    .await;
}

async fn send_consent(ws: &mut Client, channel: ChannelId, sharer: UserId) {
    send(
        ws,
        json!({
            "type": "canvas.screen_annotation", "channel_id": channel.to_string(),
            "target_user_id": sharer.to_string(), "kind": "consent",
            "allowed": true, "aspect": 1.7778,
        }),
    )
    .await;
}

#[tokio::test]
async fn a_viewers_stroke_reaches_the_sharer_in_normalised_coordinates() {
    let (store, _guard) = support::new_store("slimm-screen-annotation").await;
    let (alice_ticket, alice_id) = user_ticket_and_id(&store, "alice").await;
    store.bootstrap_deployment(alice_id).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;
    let (bob_ticket, bob_id) = user_ticket_and_id(&store, "bob").await;

    let state = support::app::builder(store.clone()).hub(Hub::new()).build();
    let addr = serve(state).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    send_stroke(
        &mut bob_ws,
        channel,
        alice_id,
        json!([0.25, 0.5, 0.75, 0.5]),
    )
    .await;

    let frame = next_of_type(&mut alice_ws, KIND).await;
    assert_eq!(frame["user_id"], bob_id.to_string());
    assert_eq!(frame["target_user_id"], alice_id.to_string());
    assert_eq!(frame["kind"], "stroke");
    assert_eq!(frame["points"], json!([0.25, 0.5, 0.75, 0.5]));
    assert_eq!(frame["color"], "red");
    assert_eq!(frame["ended"], false);
}

#[tokio::test]
async fn consent_from_the_sharer_is_relayed_with_the_screen_shape() {
    let (store, _guard) = support::new_store("slimm-screen-annotation").await;
    let (alice_ticket, alice_id) = user_ticket_and_id(&store, "alice").await;
    store.bootstrap_deployment(alice_id).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;
    let (bob_ticket, _bob_id) = user_ticket_and_id(&store, "bob").await;

    let state = support::app::builder(store.clone()).hub(Hub::new()).build();
    let addr = serve(state).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    send_consent(&mut alice_ws, channel, alice_id).await;

    let frame = next_of_type(&mut bob_ws, KIND).await;
    assert_eq!(frame["kind"], "consent");
    assert_eq!(frame["allowed"], true);
    assert_eq!(frame["aspect"], 1.7778);
}

#[tokio::test]
async fn a_viewer_cannot_speak_consent_for_the_sharer() {
    let (store, _guard) = support::new_store("slimm-screen-annotation").await;
    let (alice_ticket, alice_id) = user_ticket_and_id(&store, "alice").await;
    store.bootstrap_deployment(alice_id).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;
    let (bob_ticket, _bob_id) = user_ticket_and_id(&store, "bob").await;

    let state = support::app::builder(store.clone()).hub(Hub::new()).build();
    let addr = serve(state).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    send_consent(&mut bob_ws, channel, alice_id).await;

    assert_nothing_of_type(&mut alice_ws, KIND).await;
}

#[tokio::test]
async fn a_mark_outside_the_screen_is_dropped() {
    let (store, _guard) = support::new_store("slimm-screen-annotation").await;
    let (alice_ticket, alice_id) = user_ticket_and_id(&store, "alice").await;
    store.bootstrap_deployment(alice_id).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;
    let (bob_ticket, _bob_id) = user_ticket_and_id(&store, "bob").await;

    let state = support::app::builder(store.clone()).hub(Hub::new()).build();
    let addr = serve(state).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    send_stroke(&mut bob_ws, channel, alice_id, json!([0.5, 1.5])).await;

    assert_nothing_of_type(&mut alice_ws, KIND).await;
}

#[tokio::test]
async fn a_member_denied_use_canvas_neither_sends_nor_receives() {
    let (store, _guard) = support::new_store("slimm-screen-annotation").await;
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

    send_stroke(&mut alice_ws, channel, alice_id, json!([0.1, 0.1])).await;
    assert_nothing_of_type(&mut carol_ws, KIND).await;
    next_of_type(&mut alice_ws, KIND).await;

    send_stroke(&mut carol_ws, channel, alice_id, json!([0.2, 0.2])).await;
    assert_nothing_of_type(&mut alice_ws, KIND).await;
}

#[tokio::test]
async fn a_timed_out_member_cannot_annotate() {
    let (store, _guard) = support::new_store("slimm-screen-annotation").await;
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

    send_stroke(&mut bob_ws, channel, alice_id, json!([0.3, 0.3])).await;

    assert_nothing_of_type(&mut alice_ws, KIND).await;
}
