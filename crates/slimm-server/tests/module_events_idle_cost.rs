// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! With no module subscribed, a pushed event costs the store nothing: the
//! consumer reads which modules take an event once per module change, not once
//! per event, and still hears of a module installed afterwards.
//!
//! Counts statements through a global tracing subscriber, one test per binary,
//! because sqlx emits its events on the connection's worker thread.

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use serde_json::Value;
use slimm_server::http::spawn_module_events;
use slimm_server::hub::Event;
use slimm_server::ids::UserId;
use tracing::Subscriber;
use tracing::field::{Field, Visit};
use tracing_subscriber::Registry;
use tracing_subscriber::layer::{Context, Layer, SubscriberExt};

mod support;
use support::module_events_world::EventModule;
use support::module_world::world;
use support::wait::wait_for;
use support::wasm_fixtures::event_recorder_wasm;

const EVENTS: usize = 40;

struct CountModuleReads(Arc<AtomicUsize>);

struct MentionsModules(bool);

impl Visit for MentionsModules {
    fn record_debug(&mut self, _: &Field, value: &dyn std::fmt::Debug) {
        self.0 |= format!("{value:?}").contains("installed_modules");
    }
}

impl<S: Subscriber> Layer<S> for CountModuleReads {
    fn on_event(&self, event: &tracing::Event<'_>, _ctx: Context<'_, S>) {
        if event.metadata().target() != "sqlx::query" {
            return;
        }
        let mut seen = MentionsModules(false);
        event.record(&mut seen);
        if seen.0 {
            self.0.fetch_add(1, Ordering::Relaxed);
        }
    }
}

#[tokio::test]
async fn an_event_nobody_subscribes_to_reads_the_modules_table_once() {
    let reads = Arc::new(AtomicUsize::new(0));
    tracing::subscriber::set_global_default(
        Registry::default().with(CountModuleReads(Arc::clone(&reads))),
    )
    .expect("no other subscriber in this binary");

    let w = world("slimm-modevents-idle-cost").await;
    let _consumer = spawn_module_events(w.state.clone());
    let before = reads.load(Ordering::Relaxed);
    let read = || reads.load(Ordering::Relaxed) - before;

    for _ in 0..EVENTS {
        w.hub.publish(Event::MemberJoined(UserId::generate()));
    }
    wait_for("the consumer to look the event up", || async {
        (read() >= 1).then_some(())
    })
    .await;
    // Without the cache every event reads, so the count reaches EVENTS well inside this window.
    let _ = tokio::time::timeout(Duration::from_millis(500), async {
        while read() < EVENTS {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await;
    assert_eq!(
        read(),
        1,
        "{EVENTS} events nobody takes each read the table"
    );

    w.install_event_module(EventModule {
        id: "late",
        wasm: event_recorder_wasm(),
        subscribes: &["member.joined"],
        approved: &["events", "kv.store"],
    })
    .await;
    let newcomer = UserId::generate();
    w.hub.publish(Event::MemberJoined(newcomer));
    wait_for("the late module to hear the join", || async {
        let heard = w.recorded_events("late").await;
        heard
            .into_iter()
            .find(|e: &Value| e["data"]["user_id"] == newcomer.to_string())
    })
    .await;
}
