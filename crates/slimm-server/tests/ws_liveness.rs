// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! An authenticated socket that stops talking is closed so its slot and presence are released,
//! one that talks only to keep alive stays open, and one that never stops talking is closed too.

use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use serde_json::json;
use slimm_server::hub::Hub;
use tokio_tungstenite::tungstenite::Message as WsMessage;

mod support;

use support::wait::wait_for;
use support::ws::{Client, connect, read_frame_skipping_presence, serve, user_ticket_and_id};

const DEADLINE: Duration = Duration::from_millis(400);

async fn ping(ws: &mut Client) {
    ws.send(WsMessage::Text(json!({ "type": "ping" }).to_string()))
        .await
        .unwrap();
}

/// Whether the server ended the connection within `within`.
async fn closed_within(ws: &mut Client, within: Duration) -> bool {
    let ended = async {
        loop {
            match ws.next().await {
                None | Some(Err(_)) | Some(Ok(WsMessage::Close(_))) => return,
                Some(Ok(_)) => {}
            }
        }
    };
    tokio::time::timeout(within, ended).await.is_ok()
}

#[tokio::test]
async fn a_socket_that_goes_silent_is_closed_and_its_user_goes_offline() {
    let hub = Hub::with_liveness_deadline(DEADLINE);
    let (store, _guard) = support::new_store("slimm-ws-liveness").await;
    let (ticket, user) = user_ticket_and_id(&store, "alice").await;
    let addr = serve(support::app::builder(store).hub(hub.clone()).build()).await;

    let mut ws = connect(addr, &ticket).await;
    assert!(hub.presence().is_connected(user));

    assert!(
        closed_within(&mut ws, Duration::from_secs(3)).await,
        "a socket that sent nothing stayed open past the deadline"
    );
    wait_for("the silent user to go offline", || async {
        (!hub.presence().is_connected(user)).then_some(())
    })
    .await;
}

#[tokio::test]
async fn a_socket_that_keeps_pinging_outlives_the_deadline() {
    let hub = Hub::with_liveness_deadline(DEADLINE);
    let (store, _guard) = support::new_store("slimm-ws-liveness").await;
    let (ticket, user) = user_ticket_and_id(&store, "alice").await;
    let addr = serve(support::app::builder(store).hub(hub.clone()).build()).await;
    let mut ws = connect(addr, &ticket).await;

    let pings = 15;
    for _ in 0..pings {
        ping(&mut ws).await;
        tokio::time::sleep(DEADLINE / 4).await;
    }
    for _ in 0..pings {
        let frame = tokio::time::timeout(
            Duration::from_secs(2),
            read_frame_skipping_presence(&mut ws),
        )
        .await
        .expect("a pong for every ping");
        assert_eq!(frame["type"], "pong");
    }
    assert!(hub.presence().is_connected(user));
}

#[tokio::test]
async fn a_socket_flooding_cheap_frames_is_closed() {
    let (store, _guard) = support::new_store("slimm-ws-flood").await;
    let (ticket, user) = user_ticket_and_id(&store, "alice").await;
    let hub = Hub::new();
    let addr = serve(support::app::builder(store).hub(hub.clone()).build()).await;
    let mut ws = connect(addr, &ticket).await;

    for _ in 0..1_000 {
        let frame = WsMessage::Text(json!({ "type": "ping" }).to_string());
        if ws.send(frame).await.is_err() {
            break;
        }
    }

    assert!(
        closed_within(&mut ws, Duration::from_secs(5)).await,
        "a thousand pings in a burst did not close the socket"
    );
    wait_for("the flooding user to go offline", || async {
        (!hub.presence().is_connected(user)).then_some(())
    })
    .await;
}
