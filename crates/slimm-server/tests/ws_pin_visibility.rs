// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The `message.pinned` frame names who pinned, and never reaches a member
//! denied the channel (issue 2098).

use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use slimm_server::store::Store;
use tokio::net::TcpListener;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message as WsMessage;
use tower::ServiceExt;
use uuid::Uuid;

mod support;
use support::overwrite_harness::{app, json_body, new_store, register, request};

type Client =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

async fn frame_of_type(ws: &mut Client, kind: &str, wait: Duration) -> Option<Value> {
    tokio::time::timeout(wait, async {
        loop {
            if let Some(Ok(WsMessage::Text(text))) = ws.next().await {
                let frame: Value = serde_json::from_str(text.as_str()).unwrap();
                if frame["type"] == kind {
                    return frame;
                }
            }
        }
    })
    .await
    .ok()
}

async fn connect(store: &Store, addr: std::net::SocketAddr, token: &str) -> Client {
    let ctx = store.authenticate(token).await.unwrap().unwrap();
    let (ticket, _) = store.mint_ws_ticket(&ctx).await.unwrap();
    let (mut ws, _) = connect_async(format!("ws://{addr}/ws")).await.unwrap();
    let hello = json!({ "type": "hello", "ticket": ticket, "protocol": 1 });
    ws.send(WsMessage::Text(hello.to_string())).await.unwrap();
    assert!(
        frame_of_type(&mut ws, "hello", Duration::from_secs(2))
            .await
            .is_some()
    );
    ws
}

#[tokio::test]
async fn a_pin_frame_names_the_pinner_and_skips_members_who_cannot_see_the_channel() {
    let (store, _guard) = new_store("slimm-ws-pin-visibility").await;
    let (admin, admin_id) = register(&store, "root").await;
    let (member, _) = register(&store, "bob").await;
    let router = app(store.clone());
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let served = router.clone();
    tokio::spawn(async move { axum::serve(listener, served).await.unwrap() });
    let mut admin_ws = connect(&store, addr, &admin).await;
    let mut member_ws = connect(&store, addr, &member).await;

    let created = router
        .clone()
        .oneshot(request(
            "POST",
            "/channels",
            Some(&admin),
            Some(json!({ "name": "staff", "restricted": true })),
        ))
        .await
        .unwrap();
    let channel = json_body(created).await["id"].as_str().unwrap().to_owned();
    let sent = router
        .clone()
        .oneshot(request(
            "POST",
            &format!("/channels/{channel}/messages"),
            Some(&admin),
            Some(json!({ "id": Uuid::now_v7().to_string(), "content": "pin me" })),
        ))
        .await
        .unwrap();
    let message = json_body(sent).await["id"].as_str().unwrap().to_owned();
    let pinned = router
        .clone()
        .oneshot(request(
            "PUT",
            &format!("/channels/{channel}/messages/{message}/pin"),
            Some(&admin),
            None,
        ))
        .await
        .unwrap();
    assert!(pinned.status().is_success());

    let frame = frame_of_type(&mut admin_ws, "message.pinned", Duration::from_secs(2))
        .await
        .expect("the pinner's own client hears the pin");
    assert_eq!(frame["pinned_by"], admin_id);
    assert!(
        frame_of_type(&mut member_ws, "message.pinned", Duration::from_millis(500))
            .await
            .is_none(),
        "a member denied the channel received its pin"
    );
}
