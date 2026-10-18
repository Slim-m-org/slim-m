// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A drawing pointer's live frames cost the store a bounded number of
//! statements, not several per frame.
//!
//! Counts statements through a global tracing subscriber, one test per binary,
//! because sqlx emits its events on the connection's worker thread.

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use slimm_server::http;
use tokio::net::TcpListener;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message as WsMessage;
use tracing::Subscriber;
use tracing_subscriber::Registry;
use tracing_subscriber::layer::{Context, Layer, SubscriberExt};

mod support;

type Client =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

const FRAMES: usize = 20;

struct CountQueries(Arc<AtomicUsize>);

impl<S: Subscriber> Layer<S> for CountQueries {
    fn on_event(&self, event: &tracing::Event<'_>, _ctx: Context<'_, S>) {
        if event.metadata().target() == "sqlx::query" {
            self.0.fetch_add(1, Ordering::Relaxed);
        }
    }
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

async fn relayed(ws: &mut Client, frame_type: &str) {
    tokio::time::timeout(Duration::from_secs(2), async {
        loop {
            if let Some(Ok(WsMessage::Text(text))) = ws.next().await
                && serde_json::from_str::<Value>(text.as_str()).unwrap()["type"] == frame_type
            {
                return;
            }
        }
    })
    .await
    .unwrap_or_else(|_| panic!("no {frame_type} arrived"));
}

#[tokio::test]
async fn live_canvas_frames_cost_no_permission_queries_per_frame() {
    let counted = Arc::new(AtomicUsize::new(0));
    tracing::subscriber::set_global_default(
        Registry::default().with(CountQueries(Arc::clone(&counted))),
    )
    .expect("no other subscriber in this binary");

    let (store, _guard) = support::new_store("slimm-canvas-gate-cost").await;
    let alice = store.create_user("alice", "alice").await.unwrap();
    store.bootstrap_deployment(alice.id).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;
    let mut tickets = Vec::new();
    for name in ["draws", "watches"] {
        let user = store.create_user(name, name).await.unwrap();
        let tokens = store.open_session(user.id, "device").await.unwrap();
        let ctx = store
            .authenticate(&tokens.access_token)
            .await
            .unwrap()
            .unwrap();
        tickets.push(store.mint_ws_ticket(&ctx).await.unwrap().0);
    }

    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let router = http::router(support::app::state(store.clone()));
    tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
    let mut drawer = connect(addr, &tickets[0]).await;
    let mut watcher = connect(addr, &tickets[1]).await;

    let send_one = |n: usize| {
        json!({
            "type": "canvas.object_preview", "channel_id": channel.to_string(),
            "object_id": uuid::Uuid::now_v7().to_string(),
            "x": n as f64, "y": 0.0, "w": 10.0, "h": 10.0,
        })
        .to_string()
    };
    drawer.send(WsMessage::Text(send_one(0))).await.unwrap();
    relayed(&mut watcher, "canvas.object_preview.updated").await;

    let before = counted.load(Ordering::Relaxed);
    assert!(
        before > 0,
        "the counter saw nothing, so a zero below proves nothing"
    );
    for n in 1..=FRAMES {
        drawer.send(WsMessage::Text(send_one(n))).await.unwrap();
    }
    for _ in 0..FRAMES {
        relayed(&mut watcher, "canvas.object_preview.updated").await;
    }
    let spent = counted.load(Ordering::Relaxed) - before;
    assert!(
        spent < FRAMES,
        "{FRAMES} relayed frames cost {spent} statements; the decision should be cached"
    );
}
