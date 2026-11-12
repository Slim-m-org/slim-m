// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Neither `messages` nor `message_ops` had an index reaching `created_at`
//! before migration 0044, so both of `message_retention.rs`'s own sweep
//! passes would have paid for a full table scan under the database's one
//! write lock - the exact trap `canvas_ops`'s own history already names
//! (`tests/it_canvas/canvas_ops/index_plan.rs`), whose technique this mirrors: read
//! each query out of its real source rather than a copy, and check the
//! plan rather than trusting the migration shipped.
//!
//! The content pass is three queries (see `retention_candidates.rs`), each
//! anchored on text unique to it and required to match exactly once, so a
//! reordered or renamed query fails here instead of silently retargeting.

use std::fs;
use std::path::Path;

use slimm_server::store::Store;
use sqlx::{Row, SqlitePool};

use crate::support;
async fn new_pool(name: &str) -> (SqlitePool, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new(&format!("slimm-{name}"));
    let config = slimm_server::config::Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..slimm_server::config::Config::default()
    };
    (
        slimm_server::db::connect(&config)
            .await
            .expect("connect + migrate"),
        guard,
    )
}

/// The file without its comment lines, so a comment quoting an old query is never the one planned.
fn read_source(relative: &str) -> String {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join(relative);
    let text = fs::read_to_string(&path).unwrap_or_else(|_| panic!("read {relative}"));
    text.lines()
        .filter(|line| !line.trim_start().starts_with("//"))
        .collect::<Vec<_>>()
        .join("\n")
}

/// A whole `r#"..."#` string literal's body, given `anchor` - any unique
/// substring inside it. Mirrors `canvas_ops/index_plan.rs`'s own
/// `extract_containing`, duplicated rather than shared: each is a private
/// helper in its own separate test binary.
fn extract_containing(source: &str, anchor: &str) -> String {
    assert_eq!(
        source.matches(anchor).count(),
        1,
        "{anchor:?} must appear in exactly one query"
    );
    let pos = source
        .find(anchor)
        .unwrap_or_else(|| panic!("{anchor:?} no longer appears in the source"));
    let start = source[..pos]
        .rfind("r#\"")
        .unwrap_or_else(|| panic!("no opening quote before {anchor:?}"))
        + "r#\"".len();
    let end = source[pos..]
        .find("\"#")
        .unwrap_or_else(|| panic!("no closing quote after {anchor:?}"))
        + pos;
    source[start..end].to_owned()
}

async fn plan_of(pool: &SqlitePool, sql: &str, binds: &[i64]) -> Vec<String> {
    let explain = format!("EXPLAIN QUERY PLAN {sql}");
    let mut query = sqlx::query(&explain);
    for bind in binds {
        query = query.bind(*bind);
    }
    let rows = query
        .fetch_all(pool)
        .await
        .unwrap_or_else(|err| panic!("plan for {sql:?}: {err}"));
    rows.iter().map(|r| r.get::<String, _>("detail")).collect()
}

/// Neither table here is `WITHOUT ROWID`, so a real full scan always plans as
/// a bare `SCAN <alias>` - simpler than `canvas_ops/index_plan.rs`'s own
/// version of this, which has to tell a `WITHOUT ROWID` primary-key scan
/// apart from a real seek.
fn assert_no_scan(plan: &[String], what: &str) {
    let scan = plan.iter().find(|step| step.starts_with("SCAN"));
    assert!(
        scan.is_none(),
        "{what} fell back to a full scan; the plan is {plan:?}"
    );
}

/// `m` is `messages` in every content query; `channels` is small and may be scanned.
fn assert_never_scans_messages(plan: &[String], what: &str) {
    let scan = plan
        .iter()
        .find(|step| step.as_str() == "SCAN m" || step.starts_with("SCAN m "));
    assert!(
        scan.is_none(),
        "{what} scans every message; the plan is {plan:?}"
    );
    assert!(
        plan.iter().any(|step| step.starts_with("SEARCH m USING")),
        "{what} never seeks messages through an index; the plan is {plan:?}"
    );
}

/// Pins the index a content pass reads messages through, since that index sets its cost; see `retention_candidates.rs`.
fn assert_reads_messages_through(plan: &[String], what: &str, accepted: &[&str]) {
    assert_never_scans_messages(plan, what);
    assert!(
        accepted
            .iter()
            .any(|access| plan.contains(&format!("SEARCH m USING INDEX {access}"))),
        "{what} no longer reads messages through one of {accepted:?}; the plan is {plan:?}"
    );
}

const CONTENT_SOURCE: &str = "src/store/messages/retention_candidates.rs";
const NOW: i64 = 1_790_000_000_000;
const DAY_MS: i64 = 86_400_000;
/// Either index serves a bare channel equality, so the planner may pick whichever is cheaper.
const BY_CHANNEL: [&str; 2] = [
    "messages_channel_live (channel_id=?)",
    "messages_channel_created (channel_id=?)",
];
const BY_CHANNEL_WINDOW: [&str; 1] = ["messages_channel_created (channel_id=? AND created_at<?)"];

#[tokio::test]
async fn the_deleted_channel_pass_reads_messages_by_channel() {
    let (pool, _guard) = new_pool("retention-gone-plan").await;
    let source = read_source(CONTENT_SOURCE);
    let sql = extract_containing(&source, "WHERE c.deleted_at IS NOT NULL");
    let plan = plan_of(&pool, &sql, &[200]).await;
    assert_reads_messages_through(&plan, "the deleted-channel pass", &BY_CHANNEL);
}

/// The range on `created_at` is what lets a channel with nothing past its window cost one probe.
#[tokio::test]
async fn the_channel_window_pass_seeks_the_channel_and_created_at_index() {
    let (pool, _guard) = new_pool("retention-channel-plan").await;
    let source = read_source(CONTENT_SOURCE);
    let sql = extract_containing(&source, "WHERE cr.retention_days > 0");
    let plan = plan_of(&pool, &sql, &[NOW, DAY_MS, 200]).await;
    assert_reads_messages_through(&plan, "the channel-window pass", &BY_CHANNEL_WINDOW);
}

/// Driven from `channels`, so an exempt channel's old messages are never read only to be discarded.
#[tokio::test]
async fn the_space_window_pass_seeks_the_channel_and_created_at_index() {
    let (pool, _guard) = new_pool("retention-space-plan").await;
    let source = read_source(CONTENT_SOURCE);
    let sql = extract_containing(&source, "WHERE cr.channel_id IS NULL");
    let plan = plan_of(&pool, &sql, &[NOW - 30 * DAY_MS, 200]).await;
    assert_reads_messages_through(&plan, "the space-window pass", &BY_CHANNEL_WINDOW);
}

/// `PRAGMA optimize` runs on every connection close, so the plans must hold once statistics exist.
#[tokio::test]
async fn the_window_passes_keep_that_index_once_the_tables_are_analysed() {
    let (pool, _guard) = new_pool("retention-analysed-plan").await;
    let channel = Store::new(pool.clone())
        .create_channel("seed", "text")
        .await
        .expect("create channel")
        .id;
    sqlx::query(
        "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 3000)
         INSERT INTO messages (id, channel_id, seq, content, is_encrypted, created_at)
         SELECT randomblob(16), ?2, i, '', 1, ?1 - i FROM n",
    )
    .bind(NOW)
    .bind(channel)
    .execute(&pool)
    .await
    .expect("seed messages");
    sqlx::query("ANALYZE")
        .execute(&pool)
        .await
        .expect("analyze");
    let source = read_source(CONTENT_SOURCE);
    let channel_sql = extract_containing(&source, "WHERE cr.retention_days > 0");
    let space_sql = extract_containing(&source, "WHERE cr.channel_id IS NULL");
    let channel_plan = plan_of(&pool, &channel_sql, &[NOW, DAY_MS, 200]).await;
    let space_plan = plan_of(&pool, &space_sql, &[NOW - 30 * DAY_MS, 200]).await;
    assert_reads_messages_through(
        &channel_plan,
        "the analysed channel-window pass",
        &BY_CHANNEL_WINDOW,
    );
    assert_reads_messages_through(
        &space_plan,
        "the analysed space-window pass",
        &BY_CHANNEL_WINDOW,
    );
}

/// A plain `"..."` literal's body with its `\`-newline continuations folded, as the compiler reads it.
fn plain_literal_containing(source: &str, anchor: &str) -> String {
    assert_eq!(
        source.matches(anchor).count(),
        1,
        "{anchor:?} must appear in exactly one literal"
    );
    let pos = source.find(anchor).expect("counted above");
    let start = source[..pos].rfind('"').expect("opening quote") + 1;
    let end = source[pos..].find('"').expect("closing quote") + pos;
    source[start..end]
        .split("\\\n")
        .enumerate()
        .map(|(i, part)| if i == 0 { part } else { part.trim_start() })
        .collect()
}

/// Every retention batch looks for orphaned forwarded copies; that query is a shared column list plus a tail.
#[tokio::test]
async fn the_orphaned_copy_lookup_never_scans_messages() {
    let (pool, _guard) = new_pool("retention-orphan-plan").await;
    let source = read_source("src/store/forward_cascade.rs");
    let columns = plain_literal_containing(&source, "FROM message_forwards f");
    let tail = plain_literal_containing(&source, "JOIN messages o ON o.id = f.origin_message_id");
    let plan = plan_of(&pool, &format!("{columns}{tail}?"), &[200]).await;
    assert_never_scans_messages(&plan, "the orphaned-copy lookup");
}

#[tokio::test]
async fn the_op_log_reclaim_pass_never_scans_message_ops() {
    let (pool, _guard) = new_pool("retention-op-plan").await;
    let source = read_source("src/store/messages/message_retention.rs");
    let sql = extract_containing(&source, "DELETE FROM message_ops");
    let plan = plan_of(&pool, &sql, &[0, 2_000]).await;
    assert_no_scan(&plan, "the op-log reclaim pass");
}
