// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A warm `canvas.watch` declaration answers from the connection's permission cache, so it
//! costs the store nothing.
//!
//! Counts statements through a global tracing subscriber, one test per binary,
//! because sqlx emits its events on the connection's worker thread.

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use futures_util::SinkExt;
use serde_json::json;
use slimm_server::hub::Hub;
use tokio_tungstenite::tungstenite::Message as WsMessage;
use tracing::Subscriber;
use tracing_subscriber::Registry;
use tracing_subscriber::layer::{Context, Layer, SubscriberExt};

use crate::support;
use support::ws::{Client, connect, serve, settle, user_ticket_and_id};

struct CountQueries(Arc<AtomicUsize>);

impl<S: Subscriber> Layer<S> for CountQueries {
    fn on_event(&self, event: &tracing::Event<'_>, _ctx: Context<'_, S>) {
        if event.metadata().target() == "sqlx::query" {
            self.0.fetch_add(1, Ordering::Relaxed);
        }
    }
}

async fn watch(ws: &mut Client, channel: &str) {
    let frame = json!({ "type": "canvas.watch", "channel_ids": [channel] });
    ws.send(WsMessage::Text(frame.to_string())).await.unwrap();
    settle(ws).await;
}

#[tokio::test]
async fn a_warm_redeclaration_costs_no_queries() {
    let counted = Arc::new(AtomicUsize::new(0));
    tracing::subscriber::set_global_default(
        Registry::default().with(CountQueries(Arc::clone(&counted))),
    )
    .expect("a global subscriber needs nextest's one process per test");

    let (store, _guard) = support::new_store("slimm-canvas-viewers-cost").await;
    let (ticket, alice) = user_ticket_and_id(&store, "alice").await;
    store.bootstrap_deployment(alice).await.unwrap();
    let channel = store.create_channel("board", "canvas").await.unwrap().id;
    let state = support::app::builder(store).hub(Hub::new()).build();
    let hub = state.hub.clone();
    let mut ws = connect(serve(state).await, &ticket).await;

    watch(&mut ws, &channel.to_string()).await;
    assert_eq!(hub.canvas_viewers().entries(channel).len(), 1);
    let cold = counted.load(Ordering::Relaxed);
    ws.send(WsMessage::Text(
        json!({ "type": "canvas.watch", "channel_ids": [] }).to_string(),
    ))
    .await
    .unwrap();
    settle(&mut ws).await;
    let before = counted.load(Ordering::Relaxed);
    watch(&mut ws, &channel.to_string()).await;
    assert_eq!(hub.canvas_viewers().entries(channel).len(), 1);
    assert_eq!(
        counted.load(Ordering::Relaxed),
        before,
        "re-adding a warm board must not query (cold cost {cold} total)"
    );
}
