// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A connector's live socket is held to what its token may read over REST: no presence, no
//! member directory without `VIEW_CHANNEL`, and nothing once the admin turns it off.

use std::time::Duration;

use axum::http::StatusCode;
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use slimm_server::hub::Event;
use slimm_server::ids::UserId;
use slimm_server::permissions::Permissions;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message as WsMessage;

use super::harness::{World, world};
use crate::support;
use support::app::call;
use support::ws::{Client, read_frame};

const SEND: i64 = Permissions::SEND_MESSAGES.bits();
const VIEW: i64 = Permissions::VIEW_CHANNEL.bits() | SEND;

async fn ticket(w: &World, token: &str) -> String {
    let (status, body) = call(&w.router, "POST", "/auth/ws-ticket", Some(token), None).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    body["ticket"].as_str().unwrap().to_owned()
}

/// Every frame type up to and including the deployment-wide probe the test publishes last.
async fn frame_types_until_probe(w: &World, ws: &mut Client, other: UserId) -> Vec<String> {
    w.state.hub.publish(Event::ProfileChanged(other));
    w.state.hub.publish(Event::MemberJoined(other));
    w.state.hub.publish(Event::CategoryChanged);
    let mut seen = Vec::new();
    loop {
        let frame = read_frame(ws).await;
        let kind = frame["type"].as_str().unwrap().to_owned();
        seen.push(kind.clone());
        if kind == "category.changed" {
            return seen;
        }
    }
}

async fn another_member_online(w: &World, addr: std::net::SocketAddr) -> (UserId, Client) {
    let (_, ticket, id) = support::ws::user_ticket(&w.store, "alice").await;
    (id, support::ws::connect(addr, &ticket).await)
}

#[tokio::test]
async fn a_connector_socket_gets_no_presence_and_no_directory_frames_without_view_channel() {
    let w = world("slimm-conn-ws", &["send_messages"]).await;
    let token = w.installed(SEND).await;
    let addr = support::ws::serve(w.state.clone()).await;
    let mut ws = support::ws::connect(addr, &ticket(&w, &token).await).await;

    let (alice, _alice_ws) = another_member_online(&w, addr).await;
    let seen = frame_types_until_probe(&w, &mut ws, alice).await;
    for kind in ["presence.changed", "member.joined", "profile.changed"] {
        assert!(
            !seen.iter().any(|seen| seen == kind),
            "got {kind}: {seen:?}"
        );
    }
}

#[tokio::test]
async fn a_connector_with_view_channel_gets_the_directory_but_still_no_presence() {
    let w = world("slimm-conn-ws", &["view_channel", "send_messages"]).await;
    let token = w.installed(VIEW).await;
    let addr = support::ws::serve(w.state.clone()).await;
    let mut ws = support::ws::connect(addr, &ticket(&w, &token).await).await;

    let (alice, _alice_ws) = another_member_online(&w, addr).await;
    let seen = frame_types_until_probe(&w, &mut ws, alice).await;
    assert!(seen.iter().any(|kind| kind == "member.joined"), "{seen:?}");
    assert!(
        !seen.iter().any(|kind| kind == "presence.changed"),
        "{seen:?}"
    );
}

#[tokio::test]
async fn turning_a_connector_off_closes_its_open_socket() {
    let w = world("slimm-conn-ws", &["view_channel", "send_messages"]).await;
    let token = w.installed(VIEW).await;
    let addr = support::ws::serve(w.state.clone()).await;
    let mut ws = support::ws::connect(addr, &ticket(&w, &token).await).await;

    w.set_enabled(false).await;
    let closed = tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            match ws.next().await {
                Some(Ok(WsMessage::Text(_))) => continue,
                Some(Ok(_)) => continue,
                _ => return,
            }
        }
    })
    .await;
    assert!(closed.is_ok(), "the socket outlived the off switch");
}

#[tokio::test]
async fn a_ticket_minted_before_the_connector_was_turned_off_is_refused() {
    let w = world("slimm-conn-ws", &["view_channel", "send_messages"]).await;
    let token = w.installed(VIEW).await;
    let ticket = ticket(&w, &token).await;
    w.set_enabled(false).await;
    let addr = support::ws::serve(w.state.clone()).await;

    let (mut ws, _) = connect_async(format!("ws://{addr}/ws")).await.unwrap();
    ws.send(WsMessage::Text(
        json!({ "type": "hello", "ticket": ticket, "protocol": 1 }).to_string(),
    ))
    .await
    .unwrap();
    let frame: Value = read_frame(&mut ws).await;
    assert_eq!(frame["type"], "error");
    assert_eq!(frame["message"], "an admin has turned this connector off");
}
