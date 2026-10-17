// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Proves migration 0054's index, not just that it shipped.
//!
//! `messages_channel_live(channel_id, seq DESC)` and `messages_author(author_id)`
//! each serve half of "this author's live messages in this channel since T";
//! neither serves all three, so `message_ids_by_author_since` would otherwise
//! walk every live message the channel has ever held to find one author's.
//! The query is read out of its own source file (the `canvas_ops/index_plan.rs`
//! and `message_retention_index_plan.rs` technique) rather than copied, so an
//! edit that stops seeking the index fails here instead of only slowing down.

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

/// The whole `r#"..."#` string literal's body containing [anchor], the
/// `message_retention_index_plan.rs`/`thread_parent_index_plan.rs` technique -
/// duplicated rather than shared, since an integration test cannot import
/// another test binary's helpers.
fn extract_raw_containing(source: &str, anchor: &str) -> String {
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

async fn plan_of(pool: &SqlitePool, sql: &str) -> Vec<String> {
    let explain = format!("EXPLAIN QUERY PLAN {sql}");
    let rows = sqlx::query(&explain)
        .bind(vec![0u8; 16]) // channel_id
        .bind(vec![0u8; 16]) // author_id
        .bind(0i64) // created_at >= since_ms
        .bind(65i64) // limit
        .fetch_all(pool)
        .await
        .unwrap_or_else(|err| panic!("plan for {sql:?}: {err}"));
    rows.iter().map(|r| r.get::<String, _>("detail")).collect()
}

/// `messages` keeps its real rowid (0024 rebuilt it around one but did not
/// drop it), so a genuine full scan always plans as a bare `SCAN messages`,
/// the same reasoning `message_retention_index_plan.rs`'s own
/// `assert_no_scan` documents.
fn assert_no_scan(plan: &[String]) {
    let scan = plan.iter().find(|step| step.starts_with("SCAN"));
    assert!(
        scan.is_none(),
        "the author-plus-window selection fell back to a full scan; the plan is {plan:?}"
    );
}

fn assert_seeks_the_window_index(plan: &[String]) {
    assert!(
        plan.iter()
            .any(|step| step.contains("messages_author_channel_window")),
        "the author-plus-window selection must seek messages_author_channel_window; \
         the plan is {plan:?}"
    );
}

#[tokio::test]
async fn selecting_an_authors_recent_messages_seeks_the_window_index() {
    let (pool, _guard) = new_pool("slimm-bulk-window-plan").await;
    let source = source_of("src/store/messages/messages_bulk_window.rs");
    let sql = extract_raw_containing(&source, "FROM messages");

    let plan = plan_of(&pool, &sql).await;
    assert_seeks_the_window_index(&plan);
    assert_no_scan(&plan);
}
