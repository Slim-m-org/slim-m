// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The canvas spatial index: that the viewport read really goes through the
//! R-Tree, that the triggers keep it true for writes no Rust code performs,
//! and that its 32-bit float bounds never cost a correct answer.
//!
//! The query-plan test reads the SQL out of `src/store/canvas.rs` rather than
//! carrying its own copy. A plan assertion against a copied query proves the
//! copy uses the index, which is worth nothing.

use std::fs;
use std::path::Path;

use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ids::{CanvasObjectId, CanvasOpId, ChannelId, UserId};
use slimm_server::store::{CanvasOpRequest, PlaceRequest, Rect, Store, ViewportQuery};
use sqlx::{Row, SqlitePool};

mod support;

use support::canvas::{CanvasReads, remove_via_op};

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

fn view(min_x: f64, min_y: f64, max_x: f64, max_y: f64) -> Rect {
    Rect {
        min_x,
        min_y,
        max_x,
        max_y,
    }
}

fn cold(view: Rect) -> ViewportQuery {
    ViewportQuery {
        view,
        previous: None,
        after_seq: 0,
        limit: 1000,
    }
}

/// How many of a channel's objects a cold read of `region` returns.
async fn visible(store: &Store, channel: ChannelId, region: Rect) -> usize {
    store
        .viewport_objects(channel, &cold(region))
        .await
        .expect("viewport read")
        .len()
}

/// Places one object and returns its id.
async fn place(
    store: &Store,
    channel: ChannelId,
    author: UserId,
    bounds: (f64, f64, f64, f64),
) -> CanvasObjectId {
    let id = CanvasObjectId::generate();
    store
        .place_canvas_object(
            channel,
            author,
            id,
            PlaceRequest {
                kind: "stroke",
                bounds,
                props: "{}",
                attachment: None,
            },
        )
        .await
        .expect("placed");
    id
}

/// The exact SQL `Store::viewport_snapshot` runs, lifted out of its source.
fn viewport_sql() -> String {
    let source = Path::new(env!("CARGO_MANIFEST_DIR")).join("src/store/canvas.rs");
    let text = fs::read_to_string(&source).expect("read the canvas store module");
    let marker = "r#\"SELECT o.id AS \"id!: CanvasObjectId\"";
    let start = text
        .find(marker)
        .expect("the viewport query no longer starts the way this test finds it");
    let body = &text[start + 3..];
    let end = body.find("\"#").expect("unterminated raw string");
    body[..end].to_owned()
}

/// The viewport read and its `latest_seq` cursor share one deferred
/// transaction, so a write landing between them cannot produce a cursor the
/// page does not cover. Read as source text rather than timed, for the same
/// reason `canvas_ops.rs`'s equivalent test is: two real async tasks racing
/// each other is not a reliable way to catch a regression here.
#[test]
fn the_viewport_snapshot_reads_only_through_one_transaction() {
    let source =
        fs::read_to_string(Path::new(env!("CARGO_MANIFEST_DIR")).join("src/store/canvas.rs"))
            .expect("read the canvas store module");
    let body = support::function_body(&source, "pub async fn viewport_snapshot(");
    assert!(
        !body.contains("&self.pool"),
        "a direct pool read here would race the transaction the snapshot depends on: {body}"
    );
    assert_eq!(
        body.matches("self.begin_read()").count(),
        1,
        "viewport_snapshot must open exactly one transaction for both reads"
    );
}

/// The R-Tree has to be the outer loop, and every one of the six bounds has to
/// reach it. Left to itself on a database nothing has ever ANALYZEd, SQLite
/// drives from `canvas_objects` instead and probes the R-Tree by rowid, which
/// reads every object in the channel and prunes nothing at all - a plan that
/// still returns the right answer, so only the plan itself can catch it.
#[tokio::test]
async fn the_viewport_read_drives_from_the_rtree() {
    let (pool, _guard) = new_pool("canvas-plan").await;
    let sql = viewport_sql();
    let rows = sqlx::query(&format!("EXPLAIN QUERY PLAN {sql}"))
        .fetch_all(&pool)
        .await
        .expect("the viewport query plans");
    let plan: Vec<String> = rows.iter().map(|r| r.get::<String, _>("detail")).collect();

    let driving = plan.first().expect("a non-empty plan");
    let index = driving
        .strip_prefix("SCAN r VIRTUAL TABLE INDEX 2:")
        .unwrap_or_else(|| {
            panic!("the R-Tree is not driving the viewport read; the plan is {plan:?}")
        });
    // Two characters per constraint pushed into the R-Tree, and there are six
    // bounds: the channel key, then x and y.
    assert_eq!(
        index.len(),
        12,
        "only {} of the six viewport bounds reached the R-Tree; the plan is {plan:?}",
        index.len() / 2
    );
    assert!(
        !plan
            .iter()
            .any(|step| step.contains("canvas_objects_channel_live")),
        "the viewport read fell back to scanning the channel; the plan is {plan:?}"
    );
}

/// A write that never passes through any Rust code still leaves the index
/// true, which is the whole reason the index is trigger-maintained: the FK
/// cascade from `channels`, the Phase 6 op-log materialization, and
/// compaction all write this table without asking the application.
#[tokio::test]
async fn raw_sql_writes_still_maintain_the_index() {
    let (pool, _guard) = new_pool("canvas-triggers").await;
    let store = Store::new(pool.clone());
    let channel = store.create_channel("canvas", "voice").await.unwrap().id;
    let author = store.create_user("ann", "Ann").await.unwrap().id;
    place(&store, channel, author, (10.0, 10.0, 20.0, 20.0)).await;

    let indexed = |pool: SqlitePool| async move {
        sqlx::query_scalar::<_, i64>("SELECT count(*) FROM canvas_rtree")
            .fetch_one(&pool)
            .await
            .unwrap()
    };
    assert_eq!(indexed(pool.clone()).await, 1);

    sqlx::query(
        "INSERT INTO canvas_objects
             (id, channel_id, channel_key, kind, x, y, w, h, seq, created_at)
         VALUES (randomblob(16), ?, 7, 'stroke', 500.0, 500.0, 10.0, 10.0, 99, 0)",
    )
    .bind(channel)
    .execute(&pool)
    .await
    .unwrap();
    assert_eq!(indexed(pool.clone()).await, 2);

    sqlx::query("DELETE FROM canvas_objects WHERE seq = 99")
        .execute(&pool)
        .await
        .unwrap();
    assert_eq!(indexed(pool).await, 1);
}

/// Moving an object moves it in the index, and removing it takes it out.
#[tokio::test]
async fn the_index_follows_a_move_and_a_removal() {
    let (pool, _guard) = new_pool("canvas-move").await;
    let store = Store::new(pool);
    let channel = store.create_channel("canvas", "voice").await.unwrap().id;
    let author = store.create_user("ann", "Ann").await.unwrap().id;
    let id = place(&store, channel, author, (0.0, 0.0, 10.0, 10.0)).await;

    let here = view(-50.0, -50.0, 50.0, 50.0);
    let there = view(950.0, 950.0, 1050.0, 1050.0);
    assert_eq!(visible(&store, channel, here).await, 1);

    store
        .move_canvas_object(id, (1000.0, 1000.0, 10.0, 10.0))
        .await
        .unwrap();
    assert_eq!(
        visible(&store, channel, here).await,
        0,
        "a moved object is still indexed where it used to be"
    );
    assert_eq!(visible(&store, channel, there).await, 1);

    remove_via_op(&store, channel, author, id).await;
    assert_eq!(
        visible(&store, channel, there).await,
        0,
        "a removed object is still in the index"
    );
}

/// R-Tree coordinates are 32-bit floats and SQLite widens a bounding box when
/// it stores one, so far from the origin the index reports objects that are
/// not really in the viewport. That is safe in one direction only, and the
/// exact re-test in the query is what makes it safe: the index may over-report
/// and must never under-report.
#[tokio::test]
async fn the_index_over_reports_and_the_exact_test_cleans_up() {
    let (pool, _guard) = new_pool("canvas-precision").await;
    let store = Store::new(pool.clone());
    let channel = store.create_channel("canvas", "voice").await.unwrap().id;
    let author = store.create_user("ann", "Ann").await.unwrap().id;
    // Far enough out that one float32 step is a quarter of a pixel, and placed
    // between two of them so storing the bounds has to round outwards.
    place(&store, channel, author, (4_000_000.6, 0.0, 0.0, 0.0)).await;

    let candidates = sqlx::query_scalar::<_, i64>(
        "SELECT count(*) FROM canvas_rtree
         WHERE max_x >= 4000000.0 AND min_x <= 4000000.5
           AND max_y >= -1.0 AND min_y <= 1.0",
    )
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(
        candidates, 1,
        "this test no longer exercises over-reporting; pick coordinates that do"
    );

    let objects = store
        .viewport_objects(channel, &cold(view(4_000_000.0, -1.0, 4_000_000.5, 1.0)))
        .await
        .unwrap();
    assert!(
        objects.is_empty(),
        "an object outside the viewport came back because the index rounded its bounds outwards"
    );
}

/// One R-Tree serves the whole deployment, so a viewport read has to be
/// confined to its own channel by more than the region happening not to
/// overlap. Every canvas starts at the same origin, so they always overlap.
#[tokio::test]
async fn a_viewport_never_reaches_another_channels_canvas() {
    let (pool, _guard) = new_pool("canvas-scope").await;
    let store = Store::new(pool);
    let author = store.create_user("ann", "Ann").await.unwrap().id;
    let mine = store.create_channel("mine", "voice").await.unwrap().id;
    let theirs = store.create_channel("theirs", "voice").await.unwrap().id;
    place(&store, mine, author, (0.0, 0.0, 10.0, 10.0)).await;
    place(&store, theirs, author, (0.0, 0.0, 10.0, 10.0)).await;

    let region = view(-100.0, -100.0, 100.0, 100.0);
    assert_eq!(visible(&store, mine, region).await, 1);
    assert_eq!(visible(&store, theirs, region).await, 1);
}

/// Panning returns what the new region adds, not the whole new region: an
/// object the caller already holds from the region it is leaving is held back,
/// and one that arrived in the overlap since its cursor is not.
#[tokio::test]
async fn a_pan_returns_only_what_the_new_region_adds() {
    let (pool, _guard) = new_pool("canvas-delta").await;
    let store = Store::new(pool);
    let channel = store.create_channel("canvas", "voice").await.unwrap().id;
    let author = store.create_user("ann", "Ann").await.unwrap().id;

    let overlap = place(&store, channel, author, (450.0, 0.0, 10.0, 10.0)).await;
    let ahead = place(&store, channel, author, (900.0, 0.0, 10.0, 10.0)).await;
    let cursor = store.latest_canvas_seq(channel).await.unwrap();
    let fresh = place(&store, channel, author, (460.0, 0.0, 10.0, 10.0)).await;

    let delta = store
        .viewport_objects(
            channel,
            &ViewportQuery {
                view: view(400.0, -100.0, 1000.0, 100.0),
                previous: Some(view(0.0, -100.0, 500.0, 100.0)),
                after_seq: cursor,
                limit: 1000,
            },
        )
        .await
        .unwrap();

    let ids: Vec<CanvasObjectId> = delta.iter().map(|o| o.id).collect();
    assert!(
        ids.contains(&ahead),
        "the object being panned onto was missed"
    );
    assert!(
        ids.contains(&fresh),
        "an object newer than the cursor was missed"
    );
    assert!(
        !ids.contains(&overlap),
        "an object the caller already held was sent again"
    );
}

/// Restore's un-delete symmetry, asserted for the first time: erase takes the
/// R-Tree entry out, and restore has to put it back, or the object exists in
/// `canvas_objects` while every viewport read still answers as if it did not.
/// `canvas_rtree_au` already fires `AFTER UPDATE OF ... deleted_at`, so this
/// costs no Rust code; nothing before this asserted it held.
#[tokio::test]
async fn the_index_leaves_on_erase_and_returns_on_restore() {
    let (pool, _guard) = new_pool("canvas-restore-symmetry").await;
    let store = Store::new(pool.clone());
    let channel = store.create_channel("canvas", "voice").await.unwrap().id;
    let author = store.create_user("ann", "Ann").await.unwrap().id;
    let id = place(&store, channel, author, (0.0, 0.0, 10.0, 10.0)).await;

    let indexed = |pool: SqlitePool| async move {
        sqlx::query_scalar::<_, i64>("SELECT count(*) FROM canvas_rtree")
            .fetch_one(&pool)
            .await
            .unwrap()
    };
    let here = view(-50.0, -50.0, 50.0, 50.0);
    assert_eq!(indexed(pool.clone()).await, 1);
    assert_eq!(visible(&store, channel, here).await, 1);

    let remove_op = CanvasOpId::generate();
    let removed = store
        .submit_canvas_op(
            channel,
            author,
            remove_op,
            false,
            CanvasOpRequest::Remove(vec![id]),
        )
        .await
        .expect("remove");
    assert_eq!(removed.affected, 1);
    assert_eq!(
        indexed(pool.clone()).await,
        0,
        "erase must take the R-Tree entry out"
    );
    assert_eq!(visible(&store, channel, here).await, 0);

    let restored = store
        .submit_canvas_op(
            channel,
            author,
            CanvasOpId::generate(),
            false,
            CanvasOpRequest::Restore {
                target_op: remove_op,
            },
        )
        .await
        .expect("restore");
    assert_eq!(restored.affected, 1);
    assert_eq!(
        indexed(pool).await,
        1,
        "restore must put the R-Tree entry back"
    );
    assert_eq!(
        visible(&store, channel, here).await,
        1,
        "the object must be reachable by viewport read again, not merely undeleted"
    );
}
