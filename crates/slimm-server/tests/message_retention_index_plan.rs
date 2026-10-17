// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Neither `messages` nor `message_ops` had an index reaching `created_at`
//! before migration 0044, so both of `message_retention.rs`'s own sweep
//! passes would have paid for a full table scan under the database's one
//! write lock - the exact trap `canvas_ops`'s own history already names
//! (`tests/canvas_ops/index_plan.rs`), whose technique this mirrors: read
//! each query out of its real source rather than a copy, and check the
//! plan rather than trusting the migration shipped.

use std::fs;
use std::path::Path;

use sqlx::{Row, SqlitePool};

mod support;

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

fn read_source(relative: &str) -> String {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join(relative);
    fs::read_to_string(&path).unwrap_or_else(|_| panic!("read {relative}"))
}

/// A whole `r#"..."#` string literal's body, given `anchor` - any unique
/// substring inside it. Mirrors `canvas_ops/index_plan.rs`'s own
/// `extract_containing`, duplicated rather than shared: each is a private
/// helper in its own separate test binary.
fn extract_containing(source: &str, anchor: &str) -> String {
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

#[tokio::test]
async fn the_content_prune_pass_never_scans_messages() {
    let (pool, _guard) = new_pool("retention-content-plan").await;
    let source = read_source("src/store/messages/message_retention.rs");
    let sql = extract_containing(&source, "FROM messages");
    let plan = plan_of(&pool, &sql, &[0, 200]).await;
    assert_no_scan(&plan, "the content-prune pass");
}

#[tokio::test]
async fn the_op_log_reclaim_pass_never_scans_message_ops() {
    let (pool, _guard) = new_pool("retention-op-plan").await;
    let source = read_source("src/store/messages/message_retention.rs");
    let sql = extract_containing(&source, "DELETE FROM message_ops");
    let plan = plan_of(&pool, &sql, &[0, 2_000]).await;
    assert_no_scan(&plan, "the op-log reclaim pass");
}
