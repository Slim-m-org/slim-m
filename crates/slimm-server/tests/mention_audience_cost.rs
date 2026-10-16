// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What resolving a message's mentions costs, counted (issue 2065): a message
//! mentioning nobody must not load every account and its channel permission.
//!
//! Same statement counter as `permissions_batch_cost.rs`, global for the
//! binary, so this file is a single test.

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::hub::Hub;
use slimm_server::mentions::mentioned_viewers;
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use tracing::Subscriber;
use tracing_subscriber::Registry;
use tracing_subscriber::layer::{Context, Layer, SubscriberExt};

mod support;

struct CountQueries(Arc<AtomicUsize>);

impl<S: Subscriber> Layer<S> for CountQueries {
    fn on_event(&self, event: &tracing::Event<'_>, _ctx: Context<'_, S>) {
        if event.metadata().target() == "sqlx::query" {
            self.0.fetch_add(1, Ordering::Relaxed);
        }
    }
}

#[tokio::test]
async fn a_message_mentioning_nobody_runs_no_query() {
    let count = Arc::new(AtomicUsize::new(0));
    tracing::subscriber::set_global_default(Registry::default().with(CountQueries(count.clone())))
        .unwrap();
    let (path, _guard) = support::TestDbGuard::new("slimm-mention-cost");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let s = Store::new(db::connect(&config).await.unwrap());
    s.create_role("everyone", Permissions::VIEW_CHANNEL, true)
        .await
        .unwrap();
    let channel = s.create_channel("general", "text").await.unwrap();
    let ann = s.create_account("ann", "ann", "x").await.unwrap().id;
    for i in 0..20 {
        s.create_account(&format!("u{i}"), "u", "x").await.unwrap();
    }
    assert!(
        count.load(Ordering::Relaxed) > 0,
        "the counter must see sqlx"
    );
    let presence = Hub::new().presence();

    let before = count.load(Ordering::Relaxed);
    mentioned_viewers(&s, channel.id, ann, "no names in here", &presence)
        .await
        .unwrap();
    assert_eq!(count.load(Ordering::Relaxed) - before, 0);

    let before = count.load(Ordering::Relaxed);
    let named = mentioned_viewers(&s, channel.id, ann, "hi @u3", &presence)
        .await
        .unwrap();
    let for_a_name = count.load(Ordering::Relaxed) - before;
    assert_eq!(named.len(), 1);

    let before = count.load(Ordering::Relaxed);
    mentioned_viewers(&s, channel.id, ann, "@everyone", &presence)
        .await
        .unwrap();
    let for_everyone = count.load(Ordering::Relaxed) - before;
    assert!(
        for_a_name < for_everyone,
        "naming one person ({for_a_name}) cost as much as @everyone ({for_everyone})"
    );
}
