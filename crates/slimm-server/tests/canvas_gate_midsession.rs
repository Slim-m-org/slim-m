// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Canvas live frames are authorized from a per-connection cache, so a change
//! made while the socket stays open has to reach the very next frame.

use std::sync::Arc;
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use slimm_server::http::{self, AppState};
use slimm_server::hub::{Event, Hub};
use slimm_server::ids::{ChannelId, UserId};
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use tokio::net::TcpListener;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message as WsMessage;

mod support;

type Client =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

struct World {
    state: AppState,
    channel: ChannelId,
    alice: Client,
    bob: Client,
    bob_id: UserId,
    alice_id: UserId,
    store: Store,
    _guard: support::TestDbGuard,
}

async fn ticket_for(store: &Store, name: &str) -> (String, UserId) {
    let user = store.create_user(name, name).await.unwrap();
    let tokens = store.open_session(user.id, "device").await.unwrap();
    let ctx = store
        .authenticate(&tokens.access_token)
        .await
        .unwrap()
        .unwrap();
    let (ticket, _) = store.mint_ws_ticket(&ctx).await.unwrap();
    (ticket, user.id)
}

async fn connect(addr: std::net::SocketAddr, ticket: &str) -> Client {
    let (mut ws, _) = connect_async(format!("ws://{addr}/ws")).await.unwrap();
    ws.send(WsMessage::Text(
        json!({ "type": "hello", "ticket": ticket, "protocol": 1 }).to_string(),
    ))
    .await
    .unwrap();
    loop {
        if let Some(Ok(WsMessage::Text(text))) = ws.next().await
            && serde_json::from_str::<Value>(text.as_str()).unwrap()["type"] == "hello"
        {
            return ws;
        }
    }
}

async fn world() -> World {
    let (store, guard) = support::new_store("slimm-canvas-gate-midsession").await;
    let (alice_ticket, alice_id) = ticket_for(&store, "alice").await;
    store.bootstrap_deployment(alice_id).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;
    let (bob_ticket, bob_id) = ticket_for(&store, "bob").await;
    let state = support::app::builder(store.clone()).hub(Hub::new()).build();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let router = http::router(state.clone());
    tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
    World {
        alice: connect(addr, &alice_ticket).await,
        bob: connect(addr, &bob_ticket).await,
        state,
        channel,
        bob_id,
        alice_id,
        store,
        _guard: guard,
    }
}

async fn arrived(ws: &mut Client, frame_type: &str, wait: Duration) -> bool {
    tokio::time::timeout(wait, async {
        loop {
            if let Some(Ok(WsMessage::Text(text))) = ws.next().await
                && serde_json::from_str::<Value>(text.as_str()).unwrap()["type"] == frame_type
            {
                return;
            }
        }
    })
    .await
    .is_ok()
}

async fn send(ws: &mut Client, frame: Value) {
    ws.send(WsMessage::Text(frame.to_string())).await.unwrap();
}

async fn cursor(w: &mut World) {
    let frame =
        json!({ "type": "canvas.cursor", "channel_id": w.channel.to_string(), "x": 1.0, "y": 2.0 });
    send(&mut w.bob, frame).await;
}

async fn ink(w: &mut World) {
    let frame = json!({
        "type": "canvas.stroke_preview", "channel_id": w.channel.to_string(),
        "object_id": uuid::Uuid::now_v7().to_string(), "points": [1.0, 1.0], "ended": false,
    });
    send(&mut w.bob, frame).await;
}

const SEEN: Duration = Duration::from_secs(2);
const QUIET: Duration = Duration::from_millis(400);

#[tokio::test]
async fn a_revoked_use_canvas_stops_the_next_cursor_frame() {
    let mut w = world().await;
    cursor(&mut w).await;
    assert!(arrived(&mut w.alice, "canvas.cursor.moved", SEEN).await);

    w.store
        .set_member_overwrite(
            w.channel,
            w.bob_id,
            Permissions::NONE,
            Permissions::USE_CANVAS,
        )
        .await
        .unwrap();
    w.state.hub.publish(Event::OverwriteChanged {
        channel_id: w.channel,
        previously_visible_to: Arc::new(vec![w.bob_id]),
    });

    cursor(&mut w).await;
    assert!(!arrived(&mut w.alice, "canvas.cursor.moved", QUIET).await);
}

#[tokio::test]
async fn a_timeout_set_mid_session_refuses_the_next_ink_frame() {
    let mut w = world().await;
    ink(&mut w).await;
    assert!(arrived(&mut w.alice, "canvas.stroke_preview.updated", SEEN).await);

    let until = now_ms() + 60_000;
    w.store
        .set_member_timeout(w.bob_id, until, None, w.alice_id)
        .await
        .unwrap();
    w.state.hub.publish(Event::MemberTimeoutChanged {
        user_id: w.bob_id,
        until: Some(until),
    });

    ink(&mut w).await;
    assert!(!arrived(&mut w.alice, "canvas.stroke_preview.updated", QUIET).await);
    cursor(&mut w).await;
    assert!(
        arrived(&mut w.alice, "canvas.cursor.moved", SEEN).await,
        "a timeout freezes the pen, not the pointer"
    );
}

/// No event marks a timeout running out, so the cached expiry instant has to.
#[tokio::test]
async fn a_timeout_that_ends_mid_session_lets_ink_through_again() {
    let mut w = world().await;
    let until = now_ms() + 1_500;
    w.store
        .set_member_timeout(w.bob_id, until, None, w.alice_id)
        .await
        .unwrap();

    ink(&mut w).await;
    assert!(!arrived(&mut w.alice, "canvas.stroke_preview.updated", QUIET).await);

    // The timeout ends on the wall clock, so the behaviour under test is the waiting.
    tokio::time::sleep(Duration::from_millis(1_500)).await;
    ink(&mut w).await;
    assert!(arrived(&mut w.alice, "canvas.stroke_preview.updated", SEEN).await);
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
}
