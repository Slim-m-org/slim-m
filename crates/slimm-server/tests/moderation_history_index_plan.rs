// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Proves migration 0068's two moderation-history indexes, not just that they
//! shipped. `resolved_reports_page` orders resolved reports by
//! `(resolved_at DESC, id DESC)` and `audit_log_page` orders audit rows by
//! `(created_at DESC, id DESC)`; before 0068 neither had an index leading with
//! its predicate or order, so every page of the merged feed was a full scan
//! plus a sort. The reports query is read out of its own source file (the
//! `messages_bulk_window_index_plan.rs` technique) so an edit that stops
//! matching the index fails here rather than only slowing down.

mod support;

use std::fs;
use std::path::Path;

use sqlx::{Row, SqlitePool};

async fn new_pool(name: &str) -> (SqlitePool, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new(name);
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

fn source_of(relative: &str) -> String {
    fs::read_to_string(Path::new(env!("CARGO_MANIFEST_DIR")).join(relative))
        .unwrap_or_else(|_| panic!("read {relative}"))
}

async fn plan_of(pool: &SqlitePool, sql: &str) -> Vec<String> {
    let explain = format!("EXPLAIN QUERY PLAN {sql}");
    let rows = sqlx::query(&explain)
        .bind(50i64) // limit
        .fetch_all(pool)
        .await
        .unwrap_or_else(|err| panic!("plan for {sql:?}: {err}"));
    rows.iter().map(|r| r.get::<String, _>("detail")).collect()
}

/// An ORDER BY that an index already satisfies plans as a walk of that index
/// (`SCAN ... USING INDEX name`, or `SEARCH` when the predicate narrows it) and
/// never as `USE TEMP B-TREE FOR ORDER BY`; the sort step is what made every
/// page cost the whole table.
fn assert_walks_index(plan: &[String], index: &str) {
    assert!(
        plan.iter()
            .any(|step| step.contains(&format!("USING INDEX {index}"))),
        "the page must walk {index}; the plan is {plan:?}"
    );
    assert!(
        !plan.iter().any(|step| step.contains("TEMP B-TREE")),
        "the page must not sort after the fact; the plan is {plan:?}"
    );
}

#[tokio::test]
async fn paging_resolved_reports_walks_the_resolved_index() {
    let (pool, _guard) = new_pool("slimm-history-reports-plan").await;
    let source = source_of("src/store/moderation_history.rs");
    let base = support::query_literal_containing(&source, "FROM reports r");
    let sql = format!("{base} ORDER BY r.resolved_at DESC, r.id DESC LIMIT ?");

    let plan = plan_of(&pool, &sql).await;
    assert_walks_index(&plan, "reports_resolved");
}

#[tokio::test]
async fn paging_the_audit_log_walks_the_created_at_index() {
    let (pool, _guard) = new_pool("slimm-history-audit-plan").await;
    let sql = "SELECT id, actor_id, subject_id, action, reason, until, created_at \
               FROM moderation_audit_log WHERE 1 = 1 \
               ORDER BY created_at DESC, id DESC LIMIT ?";

    let plan = plan_of(&pool, sql).await;
    assert_walks_index(&plan, "moderation_audit_log_created_at");
}
