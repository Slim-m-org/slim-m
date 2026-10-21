// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The `active` frame: a client that reports real use stops having its keepalive pings count as activity, so a sleeping machine that keeps pinging goes away.

use std::time::{Duration, Instant};

use futures_util::SinkExt;
use serde_json::{Value, json};
use slimm_server::hub::Hub;
use slimm_server::presence;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message as WsMessage;

mod support;

use support::ws::{Client, read_frame, serve, user_ticket_and_id};

async fn send(ws: &mut Client, frame: Value) {
    ws.send(WsMessage::Text(frame.to_string())).await.unwrap();
}

/// A pong proves the server has processed every frame sent before the ping.
async fn ping_and_wait_for_pong(ws: &mut Client) {
    send(ws, json!({ "type": "ping" })).await;
    let outcome = tokio::time::timeout(Duration::from_secs(2), async {
        loop {
            if read_frame(ws).await["type"] == "pong" {
                return;
            }
        }
    })
    .await;
    assert!(outcome.is_ok(), "no pong within two seconds");
}

async fn connected(name: &str) -> (Hub, Client, slimm_server::ids::UserId, support::TestDbGuard) {
    connected_saying(name, None).await
}

async fn connected_saying(
    name: &str,
    active: Option<bool>,
) -> (Hub, Client, slimm_server::ids::UserId, support::TestDbGuard) {
    let (store, guard) = support::new_store("slimm-presence-active").await;
    let hub = Hub::new();
    let state = support::app::builder(store.clone())
        .hub(hub.clone())
        .build();
    let (ticket, id) = user_ticket_and_id(&store, name).await;
    let addr = serve(state).await;
    let (mut ws, _response) = connect_async(format!("ws://{addr}/ws")).await.unwrap();
    send(
        &mut ws,
        match active {
            Some(active) => {
                json!({ "type": "hello", "ticket": ticket, "protocol": 1, "active": active })
            }
            None => json!({ "type": "hello", "ticket": ticket, "protocol": 1 }),
        },
    )
    .await;
    assert_eq!(read_frame(&mut ws).await["type"], "hello");
    (hub, ws, id, guard)
}

fn long_ago() -> Instant {
    Instant::now() - presence::IDLE_TIMEOUT - Duration::from_secs(1)
}

#[tokio::test]
async fn an_active_frame_resets_the_idle_clock() {
    let (hub, mut ws, id, _guard) = connected("alice").await;
    hub.presence().touch_at(id, long_ago());
    assert!(hub.presence().is_idle(id));

    send(&mut ws, json!({ "type": "active" })).await;
    ping_and_wait_for_pong(&mut ws).await;

    assert!(
        !hub.presence().is_idle(id),
        "an active frame must reset the idle clock"
    );
}

#[tokio::test]
async fn after_an_active_frame_pings_no_longer_keep_the_user_online() {
    let (hub, mut ws, id, _guard) = connected("alice").await;
    send(&mut ws, json!({ "type": "active" })).await;
    ping_and_wait_for_pong(&mut ws).await;

    hub.presence().touch_at(id, long_ago());
    ping_and_wait_for_pong(&mut ws).await;

    assert!(
        hub.presence().is_idle(id),
        "a client that reports activity must go idle while only its keepalive pings arrive"
    );
}

#[tokio::test]
async fn a_client_that_never_sends_active_keeps_ping_based_presence() {
    let (hub, mut ws, id, _guard) = connected("bot").await;
    hub.presence().touch_at(id, long_ago());
    ping_and_wait_for_pong(&mut ws).await;

    assert!(
        !hub.presence().is_idle(id),
        "older clients and bots send no active frame, so their pings still count"
    );
}

#[tokio::test]
async fn a_client_that_connects_saying_nobody_is_there_starts_away() {
    let (hub, mut ws, id, _guard) = connected_saying("alice", Some(false)).await;
    ping_and_wait_for_pong(&mut ws).await;

    assert!(
        hub.presence().is_idle(id),
        "a reconnect after sleep is not use: the user must read away until an active frame"
    );

    send(&mut ws, json!({ "type": "active" })).await;
    ping_and_wait_for_pong(&mut ws).await;
    assert!(!hub.presence().is_idle(id));
}

#[tokio::test]
async fn a_client_that_connects_saying_someone_is_there_reads_online_but_pings_do_not_count() {
    let (hub, mut ws, id, _guard) = connected_saying("alice", Some(true)).await;
    ping_and_wait_for_pong(&mut ws).await;
    assert!(!hub.presence().is_idle(id));

    hub.presence().touch_at(id, long_ago());
    ping_and_wait_for_pong(&mut ws).await;
    assert!(
        hub.presence().is_idle(id),
        "declaring activity reporting in the hello turns pings off from the start"
    );
}
