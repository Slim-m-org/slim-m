// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A run of a module the host has already verified and compiled does not read
//! the stored artifact again. sqlx emits one `sqlx::query` event per
//! statement, on a worker thread, so the counter has to be the global
//! subscriber; it counts only artifact reads, so background sweeps cannot skew it.

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use tracing::Subscriber;
use tracing::field::{Field, Visit};
use tracing_subscriber::Registry;
use tracing_subscriber::layer::{Context, Layer, SubscriberExt};

mod support;
use support::module_world::{Install, world};
use support::wasm_fixtures::canned_ok_wasm;

struct CountArtifactReads(Arc<AtomicUsize>);

#[derive(Default)]
struct Statement(String);

impl Visit for Statement {
    fn record_str(&mut self, _field: &Field, value: &str) {
        self.0.push_str(value);
    }

    fn record_debug(&mut self, _field: &Field, value: &dyn std::fmt::Debug) {
        self.0.push_str(&format!("{value:?}"));
    }
}

impl<S: Subscriber> Layer<S> for CountArtifactReads {
    fn on_event(&self, event: &tracing::Event<'_>, _ctx: Context<'_, S>) {
        if event.metadata().target() != "sqlx::query" {
            return;
        }
        let mut statement = Statement::default();
        event.record(&mut statement);
        if statement.0.contains("bytes") && statement.0.contains("module_artifacts") {
            self.0.fetch_add(1, Ordering::Relaxed);
        }
    }
}

#[tokio::test]
async fn a_repeated_run_of_an_unchanged_module_does_not_read_its_artifact() {
    let count = Arc::new(AtomicUsize::new(0));
    tracing::subscriber::set_global_default(
        Registry::default().with(CountArtifactReads(count.clone())),
    )
    .expect("this binary installs the only global subscriber");
    let w = world("slimm-modcache").await;
    // The first run of anything also mints the deployment's caller key; do that with another module.
    w.install(Install {
        id: "primer",
        wasm: canned_ok_wasm("primed"),
        declared: &[],
        approved_host: &[],
    })
    .await;
    w.answer("primer").await;
    w.install(Install {
        id: "cached",
        wasm: canned_ok_wasm("hello from a module nobody has run yet"),
        declared: &[],
        approved_host: &[],
    })
    .await;

    let mut measured = Vec::new();
    for _ in 0..3 {
        let before = count.load(Ordering::Relaxed);
        w.answer("cached").await;
        measured.push(count.load(Ordering::Relaxed) - before);
    }
    assert_eq!(
        measured,
        [1, 0, 0],
        "the first run reads the artifact once and the warm ones never do"
    );
}
