// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A big retention prune must not push a websocket subscriber past the durable
//! channel's capacity: that drops the connection and every client resyncs.

use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::hub::{Event, Hub};
use slimm_server::ids::MessageId;
use slimm_server::media::Media;
use slimm_server::run_message_retention_sweep_pass;
use slimm_server::store::{NewMessage, Store};
use std::time::Duration;
use tokio::sync::broadcast::error::RecvError;

mod support;

const DAY_MS: i64 = 24 * 60 * 60 * 1000;

#[derive(Default, Debug)]
struct Tally {
    deleted: usize,
    lagged: bool,
    peak_backlog: usize,
    bytes: usize,
}

async fn seed(
    name: &str,
    count: usize,
) -> (Store, Media, support::TestDbGuard, support::TestDirGuard) {
    let (path, db) = support::TestDbGuard::new(name);
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.unwrap();
    let (root, dir) = support::TestDirGuard::new(name);
    let media = Media::new(&root, 1 << 20).unwrap();
    let store = Store::new(pool.clone());
    let user = store.create_account("ann", "Ann", "x").await.unwrap().id;
    store.bootstrap_deployment(user).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;
    store.set_message_retention_days(30).await.unwrap();
    for _ in 0..count {
        store
            .send_message(NewMessage::plain(
                channel,
                user,
                MessageId::generate(),
                "old",
            ))
            .await
            .unwrap();
    }
    sqlx::query("UPDATE messages SET created_at = ?")
        .bind(-60 * DAY_MS)
        .execute(&pool)
        .await
        .unwrap();
    (store, media, db, dir)
}

async fn prune_with_one_subscriber(name: &str, count: usize) -> Tally {
    let (store, media, _db, _dir) = seed(name, count).await;
    let hub = Hub::new();
    let mut events = hub.subscribe();
    let watcher = hub.clone();
    let reader = tokio::spawn(async move {
        let mut tally = Tally::default();
        loop {
            tally.peak_backlog = tally.peak_backlog.max(watcher.durable_backlog());
            let next = tokio::time::timeout(Duration::from_secs(5), events.recv()).await;
            let Ok(next) = next else { return tally };
            match next {
                Ok(Event::MessageDeleted {
                    channel_id,
                    message_id,
                    op_seq,
                }) => {
                    tally.deleted += 1;
                    tally.bytes += format!(
                        r#"{{"type":"message.deleted","channel_id":"{channel_id}","message_id":"{message_id}","op_seq":{}}}"#,
                        op_seq.unwrap_or(0)
                    )
                    .len();
                }
                Ok(_) => {}
                Err(RecvError::Lagged(_)) => tally.lagged = true,
                Err(RecvError::Closed) => return tally,
            }
        }
    });
    run_message_retention_sweep_pass(&store, &media, &hub).await;
    reader.await.unwrap()
}

#[tokio::test]
async fn a_big_prune_neither_lags_a_subscriber_nor_loses_a_delete() {
    let tally = prune_with_one_subscriber("slimm-burst-5000", 5_000).await;
    eprintln!("burst measurement: {tally:?}");
    assert!(!tally.lagged, "the subscriber lagged: {tally:?}");
    assert_eq!(tally.deleted, 5_000);
    assert!(
        tally.peak_backlog <= 512,
        "peak backlog {} is over half the channel",
        tally.peak_backlog
    );
}

#[tokio::test]
async fn a_stalled_subscriber_delays_a_prune_once_not_per_message() {
    let (store, media, _db, _dir) = seed("slimm-burst-stalled", 600).await;
    let hub = Hub::new();
    let _never_read = hub.subscribe();

    let started = std::time::Instant::now();
    run_message_retention_sweep_pass(&store, &media, &hub).await;

    assert!(
        started.elapsed() < Duration::from_secs(10),
        "the prune waited on a stalled subscriber for {:?}",
        started.elapsed()
    );
}
