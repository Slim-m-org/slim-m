// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The Phase 5 canvas measurement, kept as a runnable thing rather than a
//! number in a document that nobody can reproduce.
//!
//! ```text
//! cargo test --test canvas_spike -- --ignored --nocapture
//! ```
//!
//! Ignored by default because it writes hundreds of thousands of rows and
//! takes minutes. It is a measurement, not a gate: the correctness and
//! query-plan assertions that do gate live in `canvas_index.rs`.
//!
//! Everything here goes in by raw SQL in one transaction, so the triggers are
//! doing the whole job of keeping the index true. That is the trigger design
//! being exercised, not a shortcut around it.

use std::time::{Duration, Instant};

use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ids::ChannelId;
use slimm_server::store::{Rect, Store, ViewportQuery};
use sqlx::SqlitePool;

mod support;

use support::canvas::CanvasReads;

/// Objects a 1920x1080 viewport should hold, which is what the seeded world's
/// size is solved backwards from so density stays fixed as the count grows.
const PER_SCREEN: f64 = 200.0;
const SCREEN_W: f64 = 1920.0;
const SCREEN_H: f64 = 1080.0;
const OBJECT_W: f64 = 180.0;
const OBJECT_H: f64 = 140.0;

async fn new_pool(name: &str) -> (SqlitePool, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new(&format!("slimm-{name}"));
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    (
        db::connect(&config).await.expect("connect + migrate"),
        guard,
    )
}

/// The world side length that puts `PER_SCREEN` objects in one screenful.
fn world_side(count: usize) -> f64 {
    (count as f64 * SCREEN_W * SCREEN_H / PER_SCREEN).sqrt()
}

/// Fills a channel's canvas with `count` objects on a jittered grid. The
/// jitter is deterministic so two runs measure the same world.
async fn seed(pool: &SqlitePool, channel: ChannelId, count: usize) {
    let side = world_side(count);
    let cols = (count as f64).sqrt().ceil() as usize;
    let step = side / cols as f64;
    let key = channel_key(channel);

    let mut tx = pool.begin().await.expect("begin");
    for i in 0..count {
        let jitter = ((i * 7919) % 97) as f64;
        let x = (i % cols) as f64 * step + jitter;
        let y = (i / cols) as f64 * step + jitter;
        let seq = i as i64 + 1;
        sqlx::query(
            "INSERT INTO canvas_objects
                 (id, channel_id, channel_key, kind, z_index, x, y, w, h, seq, created_at)
             VALUES (randomblob(16), ?, ?, 'stroke', ?, ?, ?, ?, ?, ?, 0)",
        )
        .bind(channel)
        .bind(key)
        .bind(seq)
        .bind(x)
        .bind(y)
        .bind(OBJECT_W)
        .bind(OBJECT_H)
        .bind(seq)
        .execute(&mut *tx)
        .await
        .expect("seed insert");
    }
    // The store allocates from this counter; seeding around it would leave
    // `latest_canvas_seq` reading zero and every cursor comparison trivially true.
    sqlx::query(
        "UPDATE channel_seq_counters SET next_seq = ?
         WHERE channel_id = ? AND stream = 'canvas'",
    )
    .bind(count as i64 + 1)
    .bind(channel)
    .execute(&mut *tx)
    .await
    .expect("seed counter");
    tx.commit().await.expect("commit");
}

/// The same 24-bit discriminant the store derives, repeated here because the
/// seeding above deliberately bypasses the store.
fn channel_key(channel: ChannelId) -> i64 {
    let b = channel.0.as_bytes();
    i64::from(b[13]) << 16 | i64::from(b[14]) << 8 | i64::from(b[15])
}

/// A viewport `zoom` screens wide, centred in a world seeded for `count`.
fn centred(count: usize, zoom: f64) -> Rect {
    let centre = world_side(count) / 2.0;
    Rect {
        min_x: centre - SCREEN_W * zoom / 2.0,
        min_y: centre - SCREEN_H * zoom / 2.0,
        max_x: centre + SCREEN_W * zoom / 2.0,
        max_y: centre + SCREEN_H * zoom / 2.0,
    }
}

/// The R-Tree read, with the channel dimension (`keyed`) or without it, which
/// is what a deployment-global two-dimensional index would cost.
fn rtree_sql(keyed: bool) -> String {
    let key = if keyed {
        "r.min_key <= ?1 AND r.max_key >= ?1 AND"
    } else {
        "?1 = ?1 AND"
    };
    format!(
        "SELECT o.id, o.seq FROM canvas_rtree r
         CROSS JOIN canvas_objects o ON o.rt_id = r.rt_id
         WHERE {key}
               r.max_x >= ?2 AND r.min_x <= ?4 AND r.max_y >= ?3 AND r.min_y <= ?5
           AND o.channel_id = ?6 AND o.deleted_at IS NULL
           AND o.x <= ?4 AND o.x + o.w >= ?2 AND o.y <= ?5 AND o.y + o.h >= ?3
         ORDER BY o.z_index, o.seq LIMIT 2000"
    )
}

/// The same answer with no spatial index at all: the honest baseline, using
/// the partial index on (channel_id, seq) that the table already carries.
const NAIVE_SQL: &str = "SELECT o.id, o.seq FROM canvas_objects o
     WHERE ?1 = ?1 AND o.channel_id = ?6 AND o.deleted_at IS NULL
       AND o.x <= ?4 AND o.x + o.w >= ?2 AND o.y <= ?5 AND o.y + o.h >= ?3
     ORDER BY o.z_index, o.seq LIMIT 2000";

/// Runs one query 30 times and reports the median wall time and row count.
async fn measure(
    pool: &SqlitePool,
    sql: &str,
    channel: ChannelId,
    viewport: &Rect,
) -> (Duration, usize) {
    let key = channel_key(channel);
    let run = || async {
        sqlx::query(sql)
            .bind(key)
            .bind(viewport.min_x)
            .bind(viewport.min_y)
            .bind(viewport.max_x)
            .bind(viewport.max_y)
            .bind(channel)
            .fetch_all(pool)
            .await
            .expect("viewport read")
    };

    let rows = run().await.len();
    let mut samples = Vec::new();
    for _ in 0..30 {
        let at = Instant::now();
        let _ = run().await;
        samples.push(at.elapsed());
    }
    samples.sort();
    (samples[samples.len() / 2], rows)
}

fn row(label: &str, names: (&str, &str), fast: (Duration, usize), slow: (Duration, usize)) {
    assert_eq!(
        fast.1, slow.1,
        "{label}: the two strategies disagree on the answer"
    );
    println!(
        "{label:<34} {:>7} rows   {:>5} {:>8.3} ms   {:>5} {:>8.3} ms   {:>5.1}x",
        fast.1,
        names.0,
        fast.0.as_secs_f64() * 1000.0,
        names.1,
        slow.0.as_secs_f64() * 1000.0,
        slow.0.as_secs_f64() / fast.0.as_secs_f64(),
    );
}

/// A fresh database holding one seeded canvas.
async fn world(name: &str, count: usize) -> (SqlitePool, ChannelId, support::TestDbGuard) {
    let (pool, guard) = new_pool(name).await;
    let channel = Store::new(pool.clone())
        .create_channel("canvas", "voice")
        .await
        .unwrap()
        .id;
    seed(&pool, channel, count).await;
    (pool, channel, guard)
}

/// How the two read strategies scale as a single channel's canvas grows, with
/// object density held fixed so the answer size does not move.
#[tokio::test]
#[ignore = "Phase 5 measurement; run with --ignored --nocapture"]
async fn viewport_cost_against_object_count() {
    println!("\nOne channel, density fixed at ~{PER_SCREEN} objects per screen.\n");
    for count in [1_000usize, 5_000, 20_000, 100_000] {
        let (pool, channel, _guard) = world("spike-count", count).await;
        let viewport = centred(count, 1.0);
        let indexed = measure(&pool, &rtree_sql(true), channel, &viewport).await;
        let naive = measure(&pool, NAIVE_SQL, channel, &viewport).await;
        row(
            &format!("{count} objects, one screen"),
            ("rtree", "scan"),
            indexed,
            naive,
        );
    }
}

/// What zooming out costs. The index earns its keep by returning few rows; a
/// viewport that holds everything is the shape that takes that away.
#[tokio::test]
#[ignore = "Phase 5 measurement; run with --ignored --nocapture"]
async fn viewport_cost_against_zoom() {
    let count = 20_000usize;
    let (pool, channel, _guard) = world("spike-zoom", count).await;
    println!("\n{count} objects in one channel, zooming out.\n");

    for zoom in [1.0f64, 2.0, 4.0, 8.0, 100.0] {
        let viewport = centred(count, zoom);
        let indexed = measure(&pool, &rtree_sql(true), channel, &viewport).await;
        let naive = measure(&pool, NAIVE_SQL, channel, &viewport).await;
        row(
            &format!("{zoom:>5.0} screens wide"),
            ("rtree", "scan"),
            indexed,
            naive,
        );
    }
}

/// One R-Tree serves the deployment and every canvas starts at the same
/// origin, so without the channel dimension a read in one channel walks all of
/// them. This is what that third dimension is worth.
#[tokio::test]
#[ignore = "Phase 5 measurement; run with --ignored --nocapture"]
async fn viewport_cost_against_neighbouring_canvases() {
    let count = 20_000usize;
    let (pool, mine, _guard) = world("spike-channels", count).await;
    let store = Store::new(pool.clone());
    println!("\n{count} objects each, one read in the first channel.\n");

    for neighbours in 0..5 {
        if neighbours > 0 {
            let other = store
                .create_channel(&format!("other-{neighbours}"), "voice")
                .await
                .unwrap()
                .id;
            seed(&pool, other, count).await;
        }
        let viewport = centred(count, 1.0);
        let keyed = measure(&pool, &rtree_sql(true), mine, &viewport).await;
        let flat = measure(&pool, &rtree_sql(false), mine, &viewport).await;
        row(
            &format!("{neighbours} other canvas(es)"),
            ("3d", "2d"),
            keyed,
            flat,
        );
    }
}

/// What pinning the join order is worth. `CROSS JOIN` is the only thing making
/// the R-Tree the outer loop on a database nothing has ever ANALYZEd, and the
/// plan the planner picks instead reads the whole channel.
#[tokio::test]
#[ignore = "Phase 5 measurement; run with --ignored --nocapture"]
async fn viewport_cost_of_leaving_the_join_order_open() {
    let count = 20_000usize;
    let (pool, channel, _guard) = world("spike-join", count).await;
    let viewport = centred(count, 1.0);
    println!("\n{count} objects in one channel, one screen.\n");

    let pinned = measure(&pool, &rtree_sql(true), channel, &viewport).await;
    let open = rtree_sql(true).replace("CROSS JOIN", "JOIN");
    let open = measure(&pool, &open, channel, &viewport).await;
    row(
        "join order pinned vs left open",
        ("cross", "plain"),
        pinned,
        open,
    );
}

/// What the pan delta saves over refetching the region being entered. This one
/// runs the real store method, since the point is the rows it holds back
/// rather than the microseconds.
#[tokio::test]
#[ignore = "Phase 5 measurement; run with --ignored --nocapture"]
async fn pan_delta_against_a_cold_fetch() {
    let count = 20_000usize;
    let (pool, channel, _guard) = world("spike-delta", count).await;
    let store = Store::new(pool);
    let cursor = store.latest_canvas_seq(channel).await.unwrap();

    let before = centred(count, 1.0);
    for step in [0.25f64, 0.5, 0.75, 1.0] {
        let shift = SCREEN_W * step;
        let after = Rect {
            min_x: before.min_x + shift,
            min_y: before.min_y,
            max_x: before.max_x + shift,
            max_y: before.max_y,
        };
        let ask = |previous| ViewportQuery {
            view: after,
            previous,
            after_seq: cursor,
            limit: 5000,
        };
        let cold = store.viewport_objects(channel, &ask(None)).await.unwrap();
        let delta = store
            .viewport_objects(channel, &ask(Some(before)))
            .await
            .unwrap();
        println!(
            "pan {:>4.0}% of a screen           cold {:>5} objects   delta {:>5} objects",
            step * 100.0,
            cold.len(),
            delta.len()
        );
    }
}
