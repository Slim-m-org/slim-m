// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! How long a bulk canvas flip and a large viewport read take, kept runnable.
//!
//! ```text
//! SLIMM_MEASURE=1 cargo nextest run --test canvas_write_hold --no-capture
//! ```

use std::time::Instant;

use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ids::{CanvasOpId, ChannelId};
use slimm_server::store::{CanvasOpRequest, ClearScope, Rect, Store, ViewportQuery};
use sqlx::SqlitePool;

mod support;

use support::canvas::CanvasReads;

const PROPS_BYTES: usize = 4000;

/// Process CPU seconds, so a loaded box does not inflate the number.
fn cpu_seconds() -> f64 {
    let stat = std::fs::read_to_string("/proc/self/stat").unwrap();
    let after_comm = stat.rsplit_once(')').unwrap().1;
    let fields: Vec<&str> = after_comm.split_whitespace().collect();
    (fields[11].parse::<f64>().unwrap() + fields[12].parse::<f64>().unwrap()) / 100.0
}

async fn seeded(count: usize) -> (Store, SqlitePool, ChannelId, String, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new("slimm-write-hold");
    let config = Config {
        port: 0,
        database_path: path.clone(),
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    let store = Store::new(pool.clone());
    let channel = store.create_channel("canvas", "voice").await.unwrap().id;
    let b = channel.0.as_bytes();
    let key = i64::from(b[13]) << 16 | i64::from(b[14]) << 8 | i64::from(b[15]);
    let filler = "x".repeat(PROPS_BYTES);
    let props = format!(r#"{{"points":[0,0,1,1],"pad":"{filler}"}}"#);
    let legacy = sqlx::query_scalar::<_, i64>(
        "SELECT COUNT(*) FROM pragma_table_info('canvas_objects') WHERE name = 'props'",
    )
    .fetch_one(&pool)
    .await
    .unwrap()
        > 0;
    let mut tx = pool.begin().await.unwrap();
    for i in 0..count {
        let seq = i as i64 + 1;
        sqlx::query(
            "INSERT INTO canvas_objects
                 (id, channel_id, channel_key, kind, z_index, x, y, w, h, seq, created_at)
             VALUES (randomblob(16), ?, ?, 'stroke', ?, ?, ?, 10, 10, ?, 0)",
        )
        .bind(channel)
        .bind(key)
        .bind(seq)
        .bind((i % 200) as f64 * 12.0)
        .bind((i / 200) as f64 * 12.0)
        .bind(seq)
        .execute(&mut *tx)
        .await
        .unwrap();
        let sql = if legacy {
            "UPDATE canvas_objects SET props = ? WHERE seq = ? AND channel_id = ?"
        } else {
            "INSERT INTO canvas_object_props (object_id, props)
             SELECT id, ? FROM canvas_objects WHERE seq = ? AND channel_id = ?"
        };
        sqlx::query(sql)
            .bind(&props)
            .bind(seq)
            .bind(channel)
            .execute(&mut *tx)
            .await
            .unwrap();
    }
    sqlx::query(
        "UPDATE channel_seq_counters SET next_seq = ? WHERE channel_id = ? AND stream = 'canvas'",
    )
    .bind(count as i64 + 1)
    .bind(channel)
    .execute(&mut *tx)
    .await
    .unwrap();
    tx.commit().await.unwrap();
    (store, pool, channel, path, guard)
}

#[tokio::test]
async fn bulk_flip_and_viewport_cost() {
    if std::env::var_os("SLIMM_MEASURE").is_none() {
        return;
    }
    for count in [5_000usize, 20_000] {
        let (store, pool, channel, _path, _guard) = seeded(count).await;
        let admin = store
            .create_account("hold", "hold", "not-a-real-hash")
            .await
            .unwrap()
            .id;
        let clear_id = CanvasOpId::generate();
        let (at, cpu) = (Instant::now(), cpu_seconds());
        store
            .submit_canvas_op(
                channel,
                admin,
                clear_id,
                true,
                CanvasOpRequest::Clear {
                    before_seq: count as i64,
                    scope: ClearScope {
                        kinds: vec![],
                        author_id: None,
                    },
                },
            )
            .await
            .unwrap_or_else(|_| panic!("clear refused"));
        let clear = (at.elapsed(), cpu_seconds() - cpu);
        let (at, cpu) = (Instant::now(), cpu_seconds());
        store
            .submit_canvas_op(
                channel,
                admin,
                CanvasOpId::generate(),
                true,
                CanvasOpRequest::Restore {
                    target_op: clear_id,
                },
            )
            .await
            .unwrap_or_else(|_| panic!("restore refused"));
        let restore = (at.elapsed(), cpu_seconds() - cpu);
        let view = Rect {
            min_x: 0.0,
            min_y: 0.0,
            max_x: 3000.0,
            max_y: 3000.0,
        };
        let query = ViewportQuery {
            view,
            previous: None,
            after_seq: 0,
            limit: 2000,
        };
        let cpu = cpu_seconds();
        for _ in 0..15 {
            let _ = store.viewport_objects(channel, &query).await.unwrap();
        }
        let read_cpu = (cpu_seconds() - cpu) / 15.0;
        println!(
            "{count} objects x {PROPS_BYTES} B props: clear {:.0} ms wall / {:.0} ms cpu, restore {:.0} / {:.0} ms, viewport read (limit 2000) {:.1} ms cpu",
            clear.0.as_secs_f64() * 1e3,
            clear.1 * 1e3,
            restore.0.as_secs_f64() * 1e3,
            restore.1 * 1e3,
            read_cpu * 1e3
        );
        drop(pool);
    }
}

/// The single writer's cost of a bulk flip is the pages it dirties, and the WAL is where they land.
/// A clear that rewrote each row's props would write about as many bytes as the props hold.
#[tokio::test]
async fn a_bulk_clear_does_not_rewrite_the_props() {
    const ROWS: usize = 600;
    let (store, pool, channel, _path, _guard) = seeded(ROWS).await;
    let emptied: (i64, i64, i64) = sqlx::query_as("PRAGMA wal_checkpoint(TRUNCATE)")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(emptied, (0, 0, 0), "the seed must be out of the WAL first");
    let admin = store
        .create_account("hold", "hold", "not-a-real-hash")
        .await
        .unwrap()
        .id;
    store
        .submit_canvas_op(
            channel,
            admin,
            CanvasOpId::generate(),
            true,
            CanvasOpRequest::Clear {
                before_seq: ROWS as i64,
                scope: ClearScope {
                    kinds: vec![],
                    author_id: None,
                },
            },
        )
        .await
        .unwrap_or_else(|_| panic!("clear refused"));

    let (_, frames, _): (i64, i64, i64) = sqlx::query_as("PRAGMA wal_checkpoint(PASSIVE)")
        .fetch_one(&pool)
        .await
        .unwrap();
    let page_size: i64 = sqlx::query_scalar("PRAGMA page_size")
        .fetch_one(&pool)
        .await
        .unwrap();
    let wal = (frames * page_size) as u64;
    let props_bytes = (ROWS * PROPS_BYTES) as u64;
    assert!(
        wal < props_bytes / 4,
        "the clear wrote {wal} bytes of WAL for {props_bytes} bytes of props"
    );
}
