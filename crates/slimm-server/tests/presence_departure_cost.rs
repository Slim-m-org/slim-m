// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! When a user's last socket closes, resolving what every other connection may be told about
//! them reads the store once, not once per connection.
//!
//! Counts statements through a global tracing subscriber, one test per binary,
//! because sqlx emits its events on the connection's worker thread.

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use slimm_server::hub::Hub;
use tracing::Subscriber;
use tracing::field::{Field, Visit};
use tracing_subscriber::Registry;
use tracing_subscriber::layer::{Context, Layer, SubscriberExt};

mod support;

use support::ws::{Client, connect, read_frame, serve, user_ticket_and_id};

const OBSERVERS: usize = 6;

struct CountVisibilityReads(Arc<AtomicUsize>);

struct MentionsVisibility(bool);

impl Visit for MentionsVisibility {
    fn record_debug(&mut self, _: &Field, value: &dyn std::fmt::Debug) {
        self.0 |= format!("{value:?}").contains("presence_visibility");
    }
}

impl<S: Subscriber> Layer<S> for CountVisibilityReads {
    fn on_event(&self, event: &tracing::Event<'_>, _ctx: Context<'_, S>) {
        if event.metadata().target() != "sqlx::query" {
            return;
        }
        let mut seen = MentionsVisibility(false);
        event.record(&mut seen);
        if seen.0 {
            self.0.fetch_add(1, Ordering::Relaxed);
        }
    }
}

async fn hears_presence(ws: &mut Client, user: &str, status: &str) {
    let heard = async {
        loop {
            let frame = read_frame(ws).await;
            if frame["type"] == "presence.changed"
                && frame["user_id"] == user
                && frame["status"] == status
            {
                return;
            }
        }
    };
    tokio::time::timeout(Duration::from_secs(5), heard)
        .await
        .unwrap_or_else(|_| panic!("no {status} presence for {user} arrived"));
}

#[tokio::test]
async fn a_last_disconnect_reads_the_users_visibility_once_for_everyone() {
    let reads = Arc::new(AtomicUsize::new(0));
    tracing::subscriber::set_global_default(
        Registry::default().with(CountVisibilityReads(Arc::clone(&reads))),
    )
    .expect("no other subscriber in this binary");

    let (store, _guard) = support::new_store("slimm-presence-departure").await;
    let state = support::app::builder(store.clone()).hub(Hub::new()).build();
    let addr = serve(state).await;

    let mut observers = Vec::new();
    for n in 0..OBSERVERS {
        let (ticket, _) = user_ticket_and_id(&store, &format!("watcher{n}")).await;
        observers.push(connect(addr, &ticket).await);
    }
    let (ticket, alice) = user_ticket_and_id(&store, "alice").await;
    let alice_id = alice.to_string();
    let mut alice_ws = connect(addr, &ticket).await;
    for ws in &mut observers {
        hears_presence(ws, &alice_id, "online").await;
    }

    let before = reads.load(Ordering::Relaxed);
    alice_ws.close(None).await.unwrap();
    for ws in &mut observers {
        hears_presence(ws, &alice_id, "offline").await;
    }

    let read = reads.load(Ordering::Relaxed) - before;
    assert_eq!(
        read, 1,
        "{OBSERVERS} connections each read the user's visibility"
    );
}
