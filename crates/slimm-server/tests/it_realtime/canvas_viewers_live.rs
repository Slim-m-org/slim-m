// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Who has a board open reaches every member who can see it, from the registry's flush, and
//! `GET /presence/canvas-viewers` agrees with it.

use std::time::Duration;

use axum::Router;
use futures_util::SinkExt;
use serde_json::{Value, json};
use slimm_server::http;
use slimm_server::hub::{Event, Hub};
use slimm_server::ids::{ChannelId, UserId};
use slimm_server::permissions::Permissions;
use slimm_server::ratelimit::{Class, RateLimiter};
use slimm_server::store::Store;
use tokio_tungstenite::tungstenite::Message as WsMessage;

use crate::support;
use support::app::call_as;
use support::canvas::BoardChannels;
use support::ws::{Client, connect, read_frame, serve, settle, user_ticket, wait_for_frame};

pub(crate) struct World {
    pub(crate) hub: Hub,
    pub(crate) limiter: RateLimiter,
    pub(crate) router: Router,
    pub(crate) store: Store,
    pub(crate) board: ChannelId,
    pub(crate) alice: Client,
    pub(crate) bob: Client,
    pub(crate) alice_id: UserId,
    pub(crate) bob_id: UserId,
    pub(crate) alice_token: String,
    pub(crate) bob_token: String,
    pub(crate) _guard: support::TestDbGuard,
}

pub(crate) async fn world() -> World {
    let (store, guard) = support::new_store("slimm-canvas-viewers-live").await;
    let (alice_token, alice_ticket, alice_id) = user_ticket(&store, "alice").await;
    store.bootstrap_deployment(alice_id).await.unwrap();
    let board = store
        .create_canvas_channel("board", false)
        .await
        .unwrap()
        .id;
    let (bob_token, bob_ticket, bob_id) = user_ticket(&store, "bob").await;
    let hub = Hub::new();
    let limiter = RateLimiter::new();
    let state = support::app::builder(store.clone())
        .hub(hub.clone())
        .limiter(limiter.clone())
        .build();
    let router = http::router(state.clone());
    let addr = serve(state).await;
    World {
        alice: connect(addr, &alice_ticket).await,
        bob: connect(addr, &bob_ticket).await,
        hub,
        limiter,
        router,
        store,
        board,
        alice_id,
        bob_id,
        alice_token,
        bob_token,
        _guard: guard,
    }
}

pub(crate) async fn watch(ws: &mut Client, channels: &[ChannelId]) {
    let ids: Vec<String> = channels.iter().map(ToString::to_string).collect();
    let frame = json!({ "type": "canvas.watch", "channel_ids": ids });
    ws.send(WsMessage::Text(frame.to_string())).await.unwrap();
    settle(ws).await;
}

/// Every frame that arrives up to the next pong, minus presence noise.
async fn drain(ws: &mut Client) -> Vec<Value> {
    ws.send(WsMessage::Text(json!({ "type": "ping" }).to_string()))
        .await
        .unwrap();
    let mut seen = Vec::new();
    loop {
        let frame = read_frame(ws).await;
        match frame["type"].as_str() {
            Some("pong") => return seen,
            Some("presence.changed") => {}
            _ => seen.push(frame),
        }
    }
}

fn viewer_frames(frames: &[Value]) -> Vec<&Value> {
    frames
        .iter()
        .filter(|f| f["type"] == "canvas.viewer.changed")
        .collect()
}

pub(crate) async fn flushed(w: &mut World) -> Vec<Value> {
    slimm_server::flush_canvas_viewers(&w.hub);
    drain(&mut w.bob).await
}

#[tokio::test]
async fn a_board_opening_reaches_a_member_with_no_board_open_and_closing_and_leaving_follow() {
    let mut w = world().await;
    watch(&mut w.alice, &[w.board]).await;
    let frames = flushed(&mut w).await;
    let seen = viewer_frames(&frames);
    assert_eq!(seen.len(), 1, "{frames:?}");
    assert_eq!(seen[0]["channel_id"], w.board.to_string());
    assert_eq!(seen[0]["user_id"], w.alice_id.to_string());
    assert_eq!(seen[0]["viewing"], true);
    assert_eq!(
        seen[0].as_object().unwrap().len(),
        4,
        "only type, channel, user and viewing"
    );

    watch(&mut w.alice, &[]).await;
    let frames = flushed(&mut w).await;
    assert_eq!(viewer_frames(&frames)[0]["viewing"], false);

    watch(&mut w.alice, &[w.board]).await;
    assert_eq!(viewer_frames(&flushed(&mut w).await)[0]["viewing"], true);
    w.alice.close(None).await.unwrap();
    let gone = tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            let frames = flushed(&mut w).await;
            if let Some(frame) = viewer_frames(&frames).first() {
                return frame["viewing"].clone();
            }
        }
    })
    .await
    .expect("a disconnect publishes a leave");
    assert_eq!(gone, false);
}

#[tokio::test]
async fn the_running_flush_loop_delivers_without_a_manual_flush() {
    let mut w = world().await;
    slimm_server::spawn_canvas_viewer_flush(w.hub.clone());
    watch(&mut w.alice, &[w.board]).await;
    let frame = wait_for_frame(&mut w.bob, "canvas.viewer.changed", Duration::from_secs(10)).await;
    assert_eq!(frame.expect("a flush frame")["viewing"], true);
}

#[tokio::test]
async fn a_member_who_cannot_view_the_channel_receives_nothing_and_plants_nothing() {
    let mut w = world().await;
    w.store
        .set_member_overwrite(
            w.board,
            w.bob_id,
            Permissions::NONE,
            Permissions::VIEW_CHANNEL,
        )
        .await
        .unwrap();
    w.hub.publish(Event::OverwriteChanged {
        channel_id: w.board,
        previously_visible_to: std::sync::Arc::new(vec![w.bob_id]),
    });
    watch(&mut w.alice, &[w.board]).await;
    assert!(viewer_frames(&flushed(&mut w).await).is_empty());

    watch(&mut w.bob, &[w.board]).await;
    slimm_server::flush_canvas_viewers(&w.hub);
    assert!(
        w.hub
            .canvas_viewers()
            .entries(w.board)
            .iter()
            .all(|(user, _)| *user != w.bob_id),
        "a member without view is not registered"
    );
}

#[tokio::test]
async fn a_closed_board_registers_nobody() {
    let mut w = world().await;
    let voice = w.store.create_channel("call", "voice").await.unwrap().id;
    w.store
        .update_channel_settings(
            voice,
            slimm_server::store::ChannelPatch {
                canvas_enabled: Some(false),
                ..Default::default()
            },
        )
        .await
        .unwrap();
    watch(&mut w.alice, &[voice]).await;
    assert!(w.hub.canvas_viewers().entries(voice).is_empty());
    assert!(viewer_frames(&flushed(&mut w).await).is_empty());
}

#[tokio::test]
async fn hidden_sends_a_leave_visible_again_a_join_and_hidden_from_the_start_nothing() {
    let mut w = world().await;
    watch(&mut w.alice, &[w.board]).await;
    assert_eq!(viewer_frames(&flushed(&mut w).await).len(), 1);

    set_visibility(&w, &w.alice_token, "hidden").await;
    let frames = flushed(&mut w).await;
    assert_eq!(viewer_frames(&frames)[0]["viewing"], false, "{frames:?}");
    assert!(listed(&w, &w.bob_token).await.is_empty());
    assert_eq!(
        listed(&w, &w.alice_token).await,
        vec![w.alice_id.to_string()],
        "the caller always sees their own entry"
    );

    set_visibility(&w, &w.alice_token, "online").await;
    let frames = flushed(&mut w).await;
    assert_eq!(viewer_frames(&frames)[0]["viewing"], true, "{frames:?}");
    assert_eq!(listed(&w, &w.bob_token).await, vec![w.alice_id.to_string()]);

    watch(&mut w.alice, &[]).await;
    flushed(&mut w).await;
    set_visibility(&w, &w.alice_token, "hidden").await;
    watch(&mut w.alice, &[w.board]).await;
    watch(&mut w.alice, &[]).await;
    assert!(viewer_frames(&flushed(&mut w).await).is_empty());
}

pub(crate) async fn set_visibility(w: &World, token: &str, visibility: &str) {
    let (status, _) = call_as(
        &w.router,
        "PATCH",
        "/presence",
        token,
        Some(json!({ "visibility": visibility })),
    )
    .await;
    assert_eq!(status, 200);
}

/// The user ids the roster lists on the test board for `token`'s owner.
async fn listed(w: &World, token: &str) -> Vec<String> {
    let (status, body) = call_as(&w.router, "GET", "/presence/canvas-viewers", token, None).await;
    assert_eq!(status, 200, "{body}");
    body["channels"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|c| c["channel_id"] == w.board.to_string())
        .flat_map(|c| c["viewers"].as_array().unwrap().iter())
        .map(|v| v["user_id"].as_str().unwrap().to_owned())
        .collect()
}

#[tokio::test]
async fn turning_the_canvas_off_drops_the_channels_entries_without_a_frame() {
    let mut w = world().await;
    let voice = w.store.create_voice_with_canvas("call").await.unwrap().id;
    watch(&mut w.alice, &[voice]).await;
    assert_eq!(viewer_frames(&flushed(&mut w).await).len(), 1);

    let (status, body) = call_as(
        &w.router,
        "PATCH",
        &format!("/channels/{voice}"),
        &w.alice_token,
        Some(json!({ "canvas_enabled": false })),
    )
    .await;
    assert_eq!(status, 200, "{body}");
    assert!(w.hub.canvas_viewers().entries(voice).is_empty());
    assert!(viewer_frames(&flushed(&mut w).await).is_empty());
}

#[tokio::test]
async fn the_roster_lists_viewable_open_boards_in_arrival_order_and_not_a_member_who_lost_view() {
    let mut w = world().await;
    let hidden_board = w
        .store
        .create_canvas_channel("secret", false)
        .await
        .unwrap()
        .id;
    w.store
        .set_member_overwrite(
            hidden_board,
            w.bob_id,
            Permissions::NONE,
            Permissions::VIEW_CHANNEL,
        )
        .await
        .unwrap();
    w.hub.publish(Event::OverwriteChanged {
        channel_id: hidden_board,
        previously_visible_to: std::sync::Arc::new(vec![w.bob_id]),
    });
    watch(&mut w.bob, &[w.board]).await;
    tokio::time::sleep(Duration::from_millis(5)).await;
    watch(&mut w.alice, &[w.board, hidden_board]).await;

    let (_, body) = call_as(
        &w.router,
        "GET",
        "/presence/canvas-viewers",
        &w.alice_token,
        None,
    )
    .await;
    let boards = body["channels"].as_array().unwrap();
    assert_eq!(boards.len(), 2, "{body}");
    let ours = boards
        .iter()
        .find(|c| c["channel_id"] == w.board.to_string())
        .unwrap();
    let order: Vec<&str> = ours["viewers"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v["user_id"].as_str().unwrap())
        .collect();
    assert_eq!(order, [w.bob_id.to_string(), w.alice_id.to_string()]);
    assert!(
        ours["viewers"][0]["since"].as_i64().unwrap()
            <= ours["viewers"][1]["since"].as_i64().unwrap()
    );

    let (_, theirs) = call_as(
        &w.router,
        "GET",
        "/presence/canvas-viewers",
        &w.bob_token,
        None,
    )
    .await;
    let seen: Vec<&str> = theirs["channels"]
        .as_array()
        .unwrap()
        .iter()
        .map(|c| c["channel_id"].as_str().unwrap())
        .collect();
    assert_eq!(seen, [w.board.to_string()], "{theirs}");

    w.store
        .set_member_overwrite(
            w.board,
            w.bob_id,
            Permissions::NONE,
            Permissions::VIEW_CHANNEL,
        )
        .await
        .unwrap();
    w.hub.publish(Event::OverwriteChanged {
        channel_id: w.board,
        previously_visible_to: std::sync::Arc::new(vec![w.bob_id]),
    });
    assert_eq!(
        listed(&w, &w.alice_token).await,
        vec![w.alice_id.to_string()]
    );
}

#[tokio::test]
async fn canvas_viewers_is_a_served_capability() {
    let w = world().await;
    let (status, version) = support::app::call(&w.router, "GET", "/version", None, None).await;
    assert_eq!(status, 200);
    let caps = version["capabilities"].as_array().unwrap();
    assert!(caps.iter().any(|c| c == "canvas_viewers"), "{version}");
}

#[tokio::test]
async fn past_the_declaration_budget_removals_apply_and_additions_wait_for_the_next_accepted_one() {
    let mut w = world().await;
    watch(&mut w.alice, &[w.board]).await;
    assert_eq!(w.hub.canvas_viewers().entries(w.board).len(), 1);
    exhaust(&w).await;

    watch(&mut w.alice, &[]).await;
    assert!(
        w.hub.canvas_viewers().entries(w.board).is_empty(),
        "removal still applies"
    );
    watch(&mut w.alice, &[w.board]).await;
    assert!(
        w.hub.canvas_viewers().entries(w.board).is_empty(),
        "the addition waits"
    );

    let cursor =
        json!({ "type": "canvas.cursor", "channel_id": w.board.to_string(), "x": 1.0, "y": 2.0 });
    w.bob
        .send(WsMessage::Text(cursor.to_string()))
        .await
        .unwrap();
    let frame = wait_for_frame(&mut w.alice, "canvas.cursor.moved", Duration::from_secs(5)).await;
    assert!(
        frame.is_some(),
        "the pointer filter still took the declaration"
    );

    tokio::time::sleep(Duration::from_millis(700)).await;
    watch(&mut w.alice, &[w.board]).await;
    assert_eq!(
        w.hub.canvas_viewers().entries(w.board).len(),
        1,
        "the next accepted declaration adds it"
    );
}

#[tokio::test]
async fn a_refused_addition_registers_on_a_later_ping_once_the_budget_allows_it() {
    let mut w = world().await;
    exhaust(&w).await;
    watch(&mut w.alice, &[w.board]).await;
    assert!(w.hub.canvas_viewers().entries(w.board).is_empty());

    tokio::time::sleep(Duration::from_millis(700)).await;
    settle(&mut w.alice).await;
    assert_eq!(
        w.hub.canvas_viewers().entries(w.board).len(),
        1,
        "the declaration was kept and applied without a new one"
    );
}

/// Spends alice's whole declaration budget through the same limiter the socket uses.
async fn exhaust(w: &World) {
    let key = format!("u:{}", w.alice_id);
    while w.limiter.check(Class::CanvasWatch, &key) {}
}

#[tokio::test]
async fn delivery_needs_an_open_board_per_receiving_connection() {
    let mut w = world().await;
    let voice = w.store.create_voice_with_canvas("call").await.unwrap().id;
    w.store
        .update_channel_settings(
            voice,
            slimm_server::store::ChannelPatch {
                canvas_enabled: Some(false),
                ..Default::default()
            },
        )
        .await
        .unwrap();
    let publish = |channel_id| {
        w.hub.publish(Event::Canvas(
            slimm_server::hub::CanvasEvent::ViewerChanged {
                channel_id,
                user_id: w.alice_id,
                viewing: true,
            },
        ));
    };
    publish(voice);
    assert!(viewer_frames(&drain(&mut w.bob).await).is_empty());
    publish(w.board);
    assert_eq!(viewer_frames(&drain(&mut w.bob).await).len(), 1);
}
