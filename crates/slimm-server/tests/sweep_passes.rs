// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The background sweeps' own passes, run directly: what each records, the
//! files it frees and the events it publishes (issues 2096, 2070). The store
//! halves have their own tests; this covers the wrappers around them.

use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::hub::{Event, Hub};
use slimm_server::ids::MessageId;
use slimm_server::media::Media;
use slimm_server::store::{NewMessage, Store};
use slimm_server::{run_attachment_sweep_pass, run_message_retention_sweep_pass, run_token_sweep_pass};
use sqlx::SqlitePool;

mod support;

const DAY_MS: i64 = 24 * 60 * 60 * 1000;

struct World {
    store: Store,
    pool: SqlitePool,
    media: Media,
    _db: support::TestDbGuard,
    _dir: support::TestDirGuard,
}

async fn world(name: &str) -> World {
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
    World {
        store: Store::new(pool.clone()),
        pool,
        media,
        _db: db,
        _dir: dir,
    }
}

async fn last_reclaimed(pool: &SqlitePool, sweep: &str) -> Option<i64> {
    sqlx::query_scalar("SELECT last_reclaimed FROM sweep_status WHERE name = ?")
        .bind(sweep)
        .fetch_optional(pool)
        .await
        .unwrap()
}

#[tokio::test]
async fn the_token_pass_removes_dead_rows_and_records_its_run() {
    let w = world("slimm-pass-token").await;
    let user = w.store.create_user("ann", "Ann").await.unwrap();
    w.store.open_session(user.id, "laptop").await.unwrap();
    sqlx::query("UPDATE access_tokens SET expires_at = expires_at - ?")
        .bind(120 * DAY_MS)
        .execute(&w.pool)
        .await
        .unwrap();

    run_token_sweep_pass(&w.store).await;

    assert_eq!(last_reclaimed(&w.pool, "token").await, Some(1));
}

#[tokio::test]
async fn the_attachment_pass_deletes_an_orphans_file() {
    let w = world("slimm-pass-attachment").await;
    let sha = [0xABu8; 32];
    let hex: String = sha.iter().map(|b| format!("{b:02x}")).collect();
    w.media.write_attachment(&hex, b"orphan".to_vec()).await.unwrap();
    w.store
        .store_attachment(&sha, 6, "image/png", "orphan.png", None)
        .await
        .unwrap();
    sqlx::query("UPDATE attachments SET created_at = created_at - ?")
        .bind(30 * DAY_MS)
        .execute(&w.pool)
        .await
        .unwrap();

    run_attachment_sweep_pass(&w.store, &w.media).await;

    assert!(w.media.read_attachment(&hex).await.is_err(), "the orphan's file survived");
    assert_eq!(last_reclaimed(&w.pool, "attachments").await, Some(1));
}

#[tokio::test]
async fn the_retention_pass_announces_each_pruned_message_and_frees_its_file() {
    let w = world("slimm-pass-retention").await;
    let hub = Hub::new();
    let user = w.store.create_account("ann", "Ann", "x").await.unwrap().id;
    w.store.bootstrap_deployment(user).await.unwrap();
    let channel = w.store.list_channels().await.unwrap()[0].id;
    w.store.set_message_retention_days(30).await.unwrap();
    let sha = [0xCDu8; 32];
    let hex: String = sha.iter().map(|b| format!("{b:02x}")).collect();
    w.media.write_attachment(&hex, b"old file".to_vec()).await.unwrap();
    w.store
        .store_attachment(&sha, 8, "image/png", "old.png", Some(user))
        .await
        .unwrap();
    let id = w
        .store
        .send_message(NewMessage {
            attachment_ids: &[sha.to_vec()],
            spoiler_ids: &[],
            ..NewMessage::plain(channel, user, MessageId::generate(), "old")
        })
        .await
        .unwrap()
        .message
        .id;
    sqlx::query("UPDATE messages SET created_at = ? WHERE id = ?")
        .bind(-60 * DAY_MS)
        .bind(id)
        .execute(&w.pool)
        .await
        .unwrap();
    let mut events = hub.subscribe();

    run_message_retention_sweep_pass(&w.store, &w.media, &hub).await;

    let mut deleted = Vec::new();
    while let Ok(event) = events.try_recv() {
        if let Event::MessageDeleted { message_id, .. } = event {
            deleted.push(message_id);
        }
    }
    assert_eq!(deleted, vec![id]);
    assert!(w.media.read_attachment(&hex).await.is_err(), "the pruned message's file survived");
    assert_eq!(last_reclaimed(&w.pool, "message_retention").await, Some(1));
}
