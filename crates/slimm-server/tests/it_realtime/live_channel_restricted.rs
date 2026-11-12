// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A channel created private says so in the create response and in the
//! `channel.created` frame, so the rail draws a lock without a reload.
//!
//! `restricted` is the same for every reader (whether `@everyone` lacks
//! VIEW_CHANNEL), so it rides the event once; who receives the frame is still
//! decided per subscriber by the ordinary channel-scoped check.

use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use tokio::net::TcpListener;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message as WsMessage;
use tower::ServiceExt;

use crate::support;
use support::overwrite_harness::{app, new_store, register, request};

type Client =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

async fn next_frame(ws: &mut Client) -> Value {
    tokio::time::timeout(Duration::from_secs(2), async {
        loop {
            if let Some(Ok(WsMessage::Text(text))) = ws.next().await {
                let frame: Value = serde_json::from_str(text.as_str()).unwrap();
                if frame["type"] != "presence.changed" {
                    return frame;
                }
            }
        }
    })
    .await
    .expect("timed out waiting for a frame")
}

#[tokio::test]
async fn a_private_channel_is_created_and_announced_as_restricted() {
    let (store, _guard) = new_store("slimm-live-channel-restricted").await;
    let (admin, _) = register(&store, "root").await;
    // The hub is per router, so the listener serves the same router the request goes through.
    let router = app(store.clone());
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let served = router.clone();
    tokio::spawn(async move { axum::serve(listener, served).await.unwrap() });
    let ctx = store.authenticate(&admin).await.unwrap().unwrap();
    let (ticket, _) = store.mint_ws_ticket(&ctx).await.unwrap();
    let (mut ws, _) = connect_async(format!("ws://{addr}/ws")).await.unwrap();
    let hello = json!({ "type": "hello", "ticket": ticket, "protocol": 1 });
    ws.send(WsMessage::Text(hello.to_string())).await.unwrap();
    assert_eq!(next_frame(&mut ws).await["type"], "hello");

    for (restricted, expected) in [(true, true), (false, false)] {
        let body = json!({"name": format!("room-{restricted}"), "restricted": restricted});
        let response = router
            .clone()
            .oneshot(request("POST", "/channels", Some(&admin), Some(body)))
            .await
            .unwrap();
        let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let created: Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(created["restricted"], expected, "response: {created}");

        let frame = next_frame(&mut ws).await;
        assert_eq!(frame["type"], "channel.created");
        assert_eq!(frame["channel"]["restricted"], expected, "frame: {frame}");
    }
}
