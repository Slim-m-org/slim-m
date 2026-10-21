// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A typer who leaves (clean close or a dropped socket) before the typing TTL
//! lapses must still get `typing.stopped` to everyone watching: the stop is
//! published after the typer is already offline, and presence gating once
//! withheld it, leaving the indicator stuck on every other client.

use std::time::Duration;

use futures_util::SinkExt;
use serde_json::{Value, json};
use slimm_server::hub::Hub;
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use tokio_tungstenite::tungstenite::Message as WsMessage;

mod support;

use support::ws::{Client, connect, read_frame, serve, user_ticket_and_id};

/// Reads frames until one is `frame_type` for `channel_id`, ignoring anything
/// else (including this connection's own presence-changed frames from
/// connecting). Bounded so a missing event fails the test instead of hanging.
async fn next_of_type(ws: &mut Client, frame_type: &str, channel_id: &str) -> Value {
    let outcome = tokio::time::timeout(Duration::from_secs(2), async {
        loop {
            let frame = read_frame(ws).await;
            if frame["type"] == frame_type && frame["channel_id"] == channel_id {
                return frame;
            }
        }
    })
    .await;
    outcome.unwrap_or_else(|_| panic!("no {frame_type} for {channel_id} arrived in time"))
}

async fn send_typing(ws: &mut Client, channel_id: &str) {
    ws.send(WsMessage::Text(
        json!({ "type": "typing", "channel_id": channel_id }).to_string(),
    ))
    .await
    .unwrap();
}

const TTL: Duration = Duration::from_millis(800);

async fn watched_typing() -> (
    Client,
    Client,
    slimm_server::ids::UserId,
    String,
    support::TestDbGuard,
    Store,
) {
    let (store, guard) = support::new_store("slimm-typing-test").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let state = support::app::builder(store.clone())
        .hub(Hub::with_typing_ttl(TTL))
        .build();
    let (alice_ticket, alice_id) = user_ticket_and_id(&store, "alice").await;
    let (bob_ticket, _bob_id) = user_ticket_and_id(&store, "bob").await;
    let addr = serve(state).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;
    let channel_id = channel.id.to_string();
    send_typing(&mut alice_ws, &channel_id).await;
    next_of_type(&mut bob_ws, "typing.started", &channel_id).await;
    (alice_ws, bob_ws, alice_id, channel_id, guard, store)
}

/// Alice closes the socket properly while still inside the TTL.
#[tokio::test]
async fn typing_stops_when_the_typer_closes_cleanly() {
    let (mut alice_ws, mut bob_ws, alice_id, channel_id, _guard, _store) = watched_typing().await;
    alice_ws.close(None).await.unwrap();
    let stopped = next_of_type(&mut bob_ws, "typing.stopped", &channel_id).await;
    assert_eq!(stopped["user_id"], alice_id.to_string());
}

/// Alice's socket vanishes with no close frame (killed process, lost link).
#[tokio::test]
async fn typing_stops_when_the_typer_socket_is_dropped() {
    let (alice_ws, mut bob_ws, alice_id, channel_id, _guard, _store) = watched_typing().await;
    drop(alice_ws);
    let stopped = next_of_type(&mut bob_ws, "typing.stopped", &channel_id).await;
    assert_eq!(stopped["user_id"], alice_id.to_string());
}

/// Alice stays connected: the ordinary lapse still reaches Bob.
#[tokio::test]
async fn typing_stops_for_a_typer_who_stays_connected() {
    let (_alice_ws, mut bob_ws, _alice_id, channel_id, _guard, _store) = watched_typing().await;
    next_of_type(&mut bob_ws, "typing.stopped", &channel_id).await;
}

/// A user who goes hidden mid-typing and leaves must not have the stop
/// frame leak that they were ever typing.
#[tokio::test]
async fn a_hidden_typer_leaving_announces_no_stop() {
    use slimm_server::presence::Visibility;
    let (alice_ws, mut bob_ws, alice_id, channel_id, _guard, store) = watched_typing().await;
    store
        .set_presence_visibility(alice_id, Visibility::Hidden)
        .await
        .unwrap();
    drop(alice_ws);
    let outcome = tokio::time::timeout(
        TTL * 2 - Duration::from_millis(100),
        next_of_type(&mut bob_ws, "typing.stopped", &channel_id),
    )
    .await;
    assert!(outcome.is_err(), "a hidden typer's stop must stay withheld");
}
