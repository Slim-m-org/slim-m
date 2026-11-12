// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `refresh_tokens.session_id` had no index until migration 0042: only
//! `family_id` (0002) and `expires_at` (0019) were ever covered. The
//! revocation `UPDATE` in `revoke_session_rows` filtered on it as a full
//! scan - per session, in a loop, inside `begin_write`'s exclusive
//! transaction - and every `JOIN refresh_tokens r ON r.session_id = s.id`
//! (the push-target reads, one of which runs on every message send once
//! push is configured) made SQLite build a throwaway automatic index per
//! call. This reads both statements out of their own source files, the
//! `canvas_ops/index_plan.rs` technique, so a query edit that dodges the
//! index fails here rather than only slowing down.

use crate::support;
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

fn read_source(relative: &str) -> String {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join(relative);
    fs::read_to_string(&path).unwrap_or_else(|_| panic!("read {relative}"))
}

async fn plan_of(pool: &SqlitePool, sql: &str, bind_count: usize) -> String {
    let explain = format!("EXPLAIN QUERY PLAN {sql}");
    let mut query = sqlx::query(&explain);
    for _ in 0..bind_count {
        query = query.bind(0i64);
    }
    let rows = query
        .fetch_all(pool)
        .await
        .unwrap_or_else(|err| panic!("plan for {sql:?}: {err}"));
    rows.iter()
        .map(|r| r.get::<String, _>("detail"))
        .collect::<Vec<_>>()
        .join("\n")
}

#[tokio::test]
async fn the_revocation_update_seeks_the_session_index() {
    let (pool, _guard) = new_pool("slimm-rt-plan-update").await;
    let source = read_source("src/store/sessions.rs");
    let sql = support::query_literal_containing(
        &source,
        "UPDATE refresh_tokens SET revoked_at = ? WHERE session_id",
    );
    let plan = plan_of(&pool, &sql, 2).await;
    assert!(
        plan.contains("refresh_tokens_session"),
        "the revocation update must use the session index, got:\n{plan}"
    );
    assert!(
        !plan.contains("SCAN refresh_tokens"),
        "the revocation update must never scan, got:\n{plan}"
    );
}

/// A source-quoted representative of the `JOIN refresh_tokens r ON
/// r.session_id = s.id` shape `push_targets` and `users_with_push_devices`
/// share. Those two live in multi-line escaped strings whose literal text is
/// not valid SQL, so this asserts the shape itself: before 0042 this exact
/// join planned as an automatic covering index (a scan in disguise), and the
/// grep below is what keeps this test honest about the shape still existing.
///
/// That grep is anchored to a real query macro rather than run over the raw
/// file, because a comment quoting this join would otherwise satisfy it while
/// the query itself had changed shape. The usual scrubber is no help here:
/// the join lives inside the literal `code_only` blanks. Anchoring instead
/// proves the text sits in a live query, and panics naming the anchor when no
/// query carries it, which is what makes the call below an assertion.
#[tokio::test]
async fn the_session_join_no_longer_builds_an_automatic_index() {
    let (pool, _guard) = new_pool("slimm-rt-plan-join").await;
    let push_source = read_source("src/store/push.rs");
    support::query_literal_containing(&push_source, "JOIN refresh_tokens r ON r.session_id = s.id");

    let plan = plan_of(
        &pool,
        "SELECT s.id FROM sessions s JOIN refresh_tokens r ON r.session_id = s.id \
         WHERE s.revoked_at IS NULL",
        0,
    )
    .await;
    assert!(
        plan.contains("refresh_tokens_session"),
        "the session join must use the session index, got:\n{plan}"
    );
    assert!(
        !plan.contains("AUTOMATIC"),
        "the join must not rebuild a throwaway index per call, got:\n{plan}"
    );
}
