// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Live screen-annotation relay: a mark reaches the sharer only from someone in the sharer's call, nothing reaches anyone outside it, consent is believed only from the sharer, and the canvas gates still apply.

use std::net::SocketAddr;
use std::time::Duration;

use futures_util::SinkExt;
use serde_json::{Value, json};
use slimm_server::http::AppState;
use slimm_server::hub::Hub;
use slimm_server::ids::{ChannelId, UserId};
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use slimm_server::voice::{VoiceService, room_for_channel};
use tokio_tungstenite::tungstenite::Message as WsMessage;

use crate::support;
use support::fake_sfu::{RecordingRoomService, spawn_sfu};
use support::ws::{
    Client, assert_no_frame_of_type, connect, read_frame_of_type, serve, settle, user_ticket_and_id,
};

const KIND: &str = "canvas.screen_annotation.updated";

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
    send_consent_allowed(ws, channel, sharer, true).await;
}

async fn send_consent_allowed(ws: &mut Client, channel: ChannelId, sharer: UserId, allowed: bool) {
    send(
        ws,
        json!({
            "type": "canvas.screen_annotation", "channel_id": channel.to_string(),
            "target_user_id": sharer.to_string(), "kind": "consent",
            "allowed": allowed, "aspect": 1.7778,
        }),
    )
    .await;
}

/// The next relayed annotation of `kind`, skipping the rest: a sharer hears her own consent too.
async fn read_annotation(ws: &mut Client, kind: &str) -> Value {
    loop {
        let frame = read_frame_of_type(ws, KIND).await;
        if frame["kind"] == kind {
            return frame;
        }
    }
}

/// Serves the app with a call that seats `seated`; the room service can seat others later.
async fn serve_with_call(
    store: &Store,
    seated: &[UserId],
) -> (SocketAddr, AppState, RecordingRoomService) {
    let room = RecordingRoomService::default();
    room.seat(seated);
    let sfu = spawn_sfu(room.clone()).await;
    let voice = VoiceService::for_test(&sfu, "key", "a-secret-at-least-32-chars-long!");
    let state = support::app::builder(store.clone())
        .hub(Hub::new())
        .voice(voice)
        .build();
    (serve(state.clone()).await, state, room)
}

#[tokio::test]
async fn a_viewers_stroke_reaches_the_sharer_in_normalised_coordinates() {
    let (store, _guard) = support::new_store("slimm-screen-annotation").await;
    let (alice_ticket, alice_id) = user_ticket_and_id(&store, "alice").await;
    store.bootstrap_deployment(alice_id).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;
    let (bob_ticket, bob_id) = user_ticket_and_id(&store, "bob").await;

    let (addr, _state, _room) = serve_with_call(&store, &[alice_id, bob_id]).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    send_stroke(
        &mut bob_ws,
        channel,
        alice_id,
        json!([0.25, 0.5, 0.75, 0.5]),
    )
    .await;

    let frame = read_frame_of_type(&mut alice_ws, KIND).await;
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
    let (bob_ticket, bob_id) = user_ticket_and_id(&store, "bob").await;

    let (addr, _state, _room) = serve_with_call(&store, &[alice_id, bob_id]).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    send_consent(&mut alice_ws, channel, alice_id).await;

    let frame = read_frame_of_type(&mut bob_ws, KIND).await;
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
    let (bob_ticket, bob_id) = user_ticket_and_id(&store, "bob").await;

    let (addr, _state, _room) = serve_with_call(&store, &[alice_id, bob_id]).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    send_consent(&mut bob_ws, channel, alice_id).await;

    assert_no_frame_of_type(&mut alice_ws, KIND).await;
}

#[tokio::test]
async fn a_mark_outside_the_screen_is_dropped() {
    let (store, _guard) = support::new_store("slimm-screen-annotation").await;
    let (alice_ticket, alice_id) = user_ticket_and_id(&store, "alice").await;
    store.bootstrap_deployment(alice_id).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;
    let (bob_ticket, bob_id) = user_ticket_and_id(&store, "bob").await;

    let (addr, _state, _room) = serve_with_call(&store, &[alice_id, bob_id]).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    send_stroke(&mut bob_ws, channel, alice_id, json!([0.5, 1.5])).await;

    assert_no_frame_of_type(&mut alice_ws, KIND).await;
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

    let (addr, _state, _room) = serve_with_call(&store, &[alice_id, carol_id]).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut carol_ws = connect(addr, &carol_ticket).await;

    send_stroke(&mut alice_ws, channel, alice_id, json!([0.1, 0.1])).await;
    assert_no_frame_of_type(&mut carol_ws, KIND).await;
    read_frame_of_type(&mut alice_ws, KIND).await;

    send_stroke(&mut carol_ws, channel, alice_id, json!([0.2, 0.2])).await;
    assert_no_frame_of_type(&mut alice_ws, KIND).await;
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

    let (addr, _state, _room) = serve_with_call(&store, &[alice_id, bob_id]).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    send_stroke(&mut bob_ws, channel, alice_id, json!([0.3, 0.3])).await;

    assert_no_frame_of_type(&mut alice_ws, KIND).await;
}

#[tokio::test]
async fn a_member_outside_the_call_cannot_draw_on_the_sharers_screen() {
    let (store, _guard) = support::new_store("slimm-screen-annotation").await;
    let (alice_ticket, alice_id) = user_ticket_and_id(&store, "alice").await;
    store.bootstrap_deployment(alice_id).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;
    let (bob_ticket, bob_id) = user_ticket_and_id(&store, "bob").await;

    let (addr, state, room) = serve_with_call(&store, &[alice_id]).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    send_stroke(&mut bob_ws, channel, alice_id, json!([0.2, 0.2])).await;
    assert_no_frame_of_type(&mut alice_ws, KIND).await;

    room.seat(&[alice_id, bob_id]);
    state.voice.roster_cache().invalidate(channel);
    send_stroke(&mut bob_ws, channel, alice_id, json!([0.4, 0.4])).await;
    let frame = read_frame_of_type(&mut alice_ws, KIND).await;
    assert_eq!(frame["user_id"], bob_id.to_string());
    assert_eq!(frame["points"], json!([0.4, 0.4]));
}

#[tokio::test]
async fn a_deployment_without_voice_relays_no_marks() {
    let (store, _guard) = support::new_store("slimm-screen-annotation").await;
    let (alice_ticket, alice_id) = user_ticket_and_id(&store, "alice").await;
    store.bootstrap_deployment(alice_id).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;
    let (bob_ticket, _bob_id) = user_ticket_and_id(&store, "bob").await;

    let state = support::app::builder(store.clone()).hub(Hub::new()).build();
    let addr = serve(state).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    send_stroke(&mut bob_ws, channel, alice_id, json!([0.2, 0.2])).await;

    assert_no_frame_of_type(&mut alice_ws, KIND).await;
}

#[tokio::test]
async fn a_sharer_who_left_the_call_can_still_withdraw_consent() {
    let (store, _guard) = support::new_store("slimm-screen-annotation").await;
    let (alice_ticket, alice_id) = user_ticket_and_id(&store, "alice").await;
    store.bootstrap_deployment(alice_id).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;
    let (bob_ticket, bob_id) = user_ticket_and_id(&store, "bob").await;

    let (addr, _state, _room) = serve_with_call(&store, &[bob_id]).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    send_consent_allowed(&mut alice_ws, channel, alice_id, false).await;

    let frame = read_frame_of_type(&mut bob_ws, KIND).await;
    assert_eq!(frame["kind"], "consent");
    assert_eq!(frame["allowed"], false);
}

#[tokio::test]
async fn a_member_in_another_call_cannot_draw_on_the_sharers_screen() {
    let (store, _guard) = support::new_store("slimm-screen-annotation").await;
    let (alice_ticket, alice_id) = user_ticket_and_id(&store, "alice").await;
    store.bootstrap_deployment(alice_id).await.unwrap();
    let call_a = store.create_channel("call-a", "voice").await.unwrap().id;
    let call_b = store.create_channel("call-b", "voice").await.unwrap().id;
    let (bob_ticket, bob_id) = user_ticket_and_id(&store, "bob").await;
    let (carol_ticket, carol_id) = user_ticket_and_id(&store, "carol").await;

    let (addr, _state, room) = serve_with_call(&store, &[]).await;
    room.seat_in(&room_for_channel(call_a), &[alice_id, carol_id]);
    room.seat_in(&room_for_channel(call_b), &[bob_id]);
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;
    let mut carol_ws = connect(addr, &carol_ticket).await;

    send_stroke(&mut bob_ws, call_b, alice_id, json!([0.2, 0.2])).await;
    settle(&mut bob_ws).await;
    assert_no_frame_of_type(&mut alice_ws, KIND).await;
    assert_no_frame_of_type(&mut carol_ws, KIND).await;

    send_stroke(&mut carol_ws, call_a, alice_id, json!([0.4, 0.4])).await;
    let frame = read_frame_of_type(&mut alice_ws, KIND).await;
    assert_eq!(frame["user_id"], carol_id.to_string());
}

#[tokio::test]
async fn a_member_with_canvas_access_outside_the_call_receives_nothing() {
    let (store, _guard) = support::new_store("slimm-screen-annotation").await;
    let (alice_ticket, alice_id) = user_ticket_and_id(&store, "alice").await;
    store.bootstrap_deployment(alice_id).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;
    let (bob_ticket, bob_id) = user_ticket_and_id(&store, "bob").await;
    let (erin_ticket, _erin_id) = user_ticket_and_id(&store, "erin").await;

    let (addr, _state, _room) = serve_with_call(&store, &[alice_id, bob_id]).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;
    let mut erin_ws = connect(addr, &erin_ticket).await;

    send_consent(&mut alice_ws, channel, alice_id).await;
    read_annotation(&mut bob_ws, "consent").await;
    send_stroke(&mut bob_ws, channel, alice_id, json!([0.3, 0.3])).await;
    read_annotation(&mut alice_ws, "stroke").await;

    assert_no_frame_of_type(&mut erin_ws, KIND).await;
}

#[tokio::test]
async fn a_mark_reaches_everyone_in_the_call() {
    let (store, _guard) = support::new_store("slimm-screen-annotation").await;
    let (alice_ticket, alice_id) = user_ticket_and_id(&store, "alice").await;
    store.bootstrap_deployment(alice_id).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;
    let (bob_ticket, bob_id) = user_ticket_and_id(&store, "bob").await;
    let (carol_ticket, carol_id) = user_ticket_and_id(&store, "carol").await;

    let (addr, _state, _room) = serve_with_call(&store, &[alice_id, bob_id, carol_id]).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;
    let mut carol_ws = connect(addr, &carol_ticket).await;

    send_stroke(&mut bob_ws, channel, alice_id, json!([0.6, 0.6])).await;

    for ws in [&mut alice_ws, &mut carol_ws] {
        let frame = read_annotation(ws, "stroke").await;
        assert_eq!(frame["user_id"], bob_id.to_string());
        assert_eq!(frame["target_user_id"], alice_id.to_string());
    }
}

#[tokio::test]
async fn two_calls_at_once_each_hear_only_their_own_marks() {
    let (store, _guard) = support::new_store("slimm-screen-annotation").await;
    let (alice_ticket, alice_id) = user_ticket_and_id(&store, "alice").await;
    store.bootstrap_deployment(alice_id).await.unwrap();
    let call_a = store.create_channel("call-a", "voice").await.unwrap().id;
    let call_b = store.create_channel("call-b", "voice").await.unwrap().id;
    let (carol_ticket, carol_id) = user_ticket_and_id(&store, "carol").await;
    let (bob_ticket, bob_id) = user_ticket_and_id(&store, "bob").await;
    let (dave_ticket, dave_id) = user_ticket_and_id(&store, "dave").await;

    let (addr, _state, room) = serve_with_call(&store, &[]).await;
    room.seat_in(&room_for_channel(call_a), &[alice_id, carol_id]);
    room.seat_in(&room_for_channel(call_b), &[bob_id, dave_id]);
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut carol_ws = connect(addr, &carol_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;
    let mut dave_ws = connect(addr, &dave_ticket).await;

    send_consent(&mut alice_ws, call_a, alice_id).await;
    read_annotation(&mut carol_ws, "consent").await;
    send_stroke(&mut carol_ws, call_a, alice_id, json!([0.2, 0.2])).await;
    assert_eq!(
        read_annotation(&mut alice_ws, "stroke").await["user_id"],
        carol_id.to_string()
    );
    read_annotation(&mut carol_ws, "stroke").await;
    assert_no_frame_of_type(&mut bob_ws, KIND).await;
    assert_no_frame_of_type(&mut dave_ws, KIND).await;

    send_consent(&mut bob_ws, call_b, bob_id).await;
    read_annotation(&mut dave_ws, "consent").await;
    send_stroke(&mut dave_ws, call_b, bob_id, json!([0.8, 0.8])).await;
    let frame = read_annotation(&mut bob_ws, "stroke").await;
    assert_eq!(frame["user_id"], dave_id.to_string());
    assert_eq!(frame["channel_id"], call_b.to_string());
    assert_no_frame_of_type(&mut alice_ws, KIND).await;
    assert_no_frame_of_type(&mut carol_ws, KIND).await;
}

#[tokio::test]
async fn a_slow_roster_read_never_holds_up_the_drawers_socket() {
    let (store, _guard) = support::new_store("slimm-screen-annotation").await;
    let (alice_ticket, alice_id) = user_ticket_and_id(&store, "alice").await;
    store.bootstrap_deployment(alice_id).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;
    let (bob_ticket, bob_id) = user_ticket_and_id(&store, "bob").await;

    let (addr, _state, room) = serve_with_call(&store, &[alice_id, bob_id]).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;
    room.delay_listing(Duration::from_millis(2500));

    send_stroke(&mut bob_ws, channel, alice_id, json!([0.1, 0.1])).await;
    send_stroke(&mut bob_ws, channel, alice_id, json!([0.2, 0.2])).await;
    tokio::time::timeout(Duration::from_millis(1200), settle(&mut bob_ws))
        .await
        .expect("the socket answered while the roster read was still out");

    for points in [json!([0.1, 0.1]), json!([0.2, 0.2])] {
        assert_eq!(
            read_annotation(&mut alice_ws, "stroke").await["points"],
            points
        );
    }
}
