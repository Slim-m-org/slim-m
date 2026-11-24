// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The four predicates migration 0047 covers, each read out of the source it
//! really runs from, the `canvas_ops/index_plan.rs` technique. Asserting the
//! migration shipped would only prove the index exists; reading the query
//! back means an edit that stops using the index fails here rather than
//! quietly returning to a full scan.

use crate::support;
use std::fs;
use std::path::Path;

use sqlx::{AssertSqlSafe, Row, SqlitePool};

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

/// The deletion statements live in the module and its children.
fn deletion_source() -> String {
    let mut source = source_of("src/store/account_deletion.rs");
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("src/store/account_deletion");
    let mut children: Vec<_> = fs::read_dir(&dir)
        .expect("list account_deletion")
        .map(|entry| entry.expect("entry").path())
        .collect();
    children.sort();
    for child in children {
        source += &fs::read_to_string(&child).expect("read a deletion module");
    }
    source
}

/// Tables a deletion may scan, because nothing makes them grow with use.
const SMALL_TABLES: &[(&str, &str)] = &[
    ("access_tokens", "one per live session, swept once expired"),
    ("account_purges", "one row per deletion still running"),
    ("bot_tokens", "one per bot"),
    (
        "canvas_object_locks",
        "one per locked object, released by hand",
    ),
    ("category_overwrites", "configuration"),
    ("channels", "configuration"),
    (
        "interactions",
        "swept a quarter of an hour after each press",
    ),
    ("invite_redemptions", "one per member who joined"),
    ("link_handoffs", "one per sign-in handoff in flight"),
    ("link_states", "one per linking attempt in flight"),
    ("member_nicknames", "one per member"),
    (
        "password_reset_codes",
        "one per reset issued, swept on expiry",
    ),
    ("soundboard_clips", "capped per space"),
    ("users", "one per member"),
    ("webhooks", "configuration"),
    ("ws_tickets", "lives seconds, swept once expired"),
];

/// Every table an `EXPLAIN QUERY PLAN` step reads by scanning.
fn scanned_tables(plan: &[String]) -> Vec<String> {
    plan.iter()
        .filter(|step| {
            step.starts_with("SCAN") || (step.contains("USING PRIMARY KEY") && !step.contains('('))
        })
        .filter_map(|step| step.split_whitespace().nth(1).map(str::to_owned))
        .collect()
}

/// A long-lived account's deletion must not scan anything that grows with use,
/// or it holds the writer for as long as the table is big.
#[tokio::test]
async fn no_deletion_statement_scans_a_table_that_grows() {
    let (pool, _guard) = new_pool("slimm-deletion-plan-all").await;
    let mut scans = Vec::new();
    let literals = support::query_literals(&deletion_source());
    assert!(
        literals.len() > 50,
        "found only {} statements",
        literals.len()
    );
    for sql in literals {
        let plan = plan_of(&pool, &sql, sql.matches('?').count()).await;
        for table in scanned_tables(&plan) {
            if !SMALL_TABLES.iter().any(|(small, _)| *small == table) {
                scans.push(format!("{table}: {sql}"));
            }
        }
    }
    assert!(
        scans.is_empty(),
        "these deletion statements scan a table that grows with use; index the \
         column, or add the table to SMALL_TABLES with the reason it stays small: {scans:#?}"
    );
}

/// A 16-byte blob per placeholder, matching the affinity of the id columns
/// every query here binds; `0i64` plans the same but claims the wrong type.
async fn plan_of(pool: &SqlitePool, sql: &str, binds: usize) -> Vec<String> {
    let explain = format!("EXPLAIN QUERY PLAN {sql}");
    let mut query = sqlx::query(AssertSqlSafe(explain));
    for _ in 0..binds {
        query = query.bind(vec![0u8; 16]);
    }
    query
        .fetch_all(pool)
        .await
        .expect("plan")
        .iter()
        .map(|row| row.get::<String, _>("detail"))
        .collect()
}

/// The `canvas_ops/index_plan.rs` check rather than a bare `SCAN` prefix:
/// every table here is WITHOUT ROWID, where a full scan can also plan as
/// `SEARCH ... USING PRIMARY KEY` with no constraint in parentheses.
fn assert_no_scan(plan: &[String], what: &str) {
    let scan = plan.iter().find(|step| {
        step.starts_with("SCAN") || (step.contains("USING PRIMARY KEY") && !step.contains('('))
    });
    assert!(
        scan.is_none(),
        "{what} fell back to a full scan; the plan is {plan:?}"
    );
}

fn assert_uses(plan: &[String], index: &str, what: &str) {
    assert!(
        plan.iter().any(|step| step.contains(index)),
        "{what} must seek {index}; the plan is {plan:?}"
    );
}

#[tokio::test]
async fn deleting_an_account_seeks_the_reactions_index() {
    let (pool, _guard) = new_pool("slimm-deletion-plan-reactions").await;
    let source = deletion_source();
    let sql = support::query_literal_containing(&source, "DELETE FROM reactions WHERE user_id");

    let plan = plan_of(&pool, &sql, 1).await;
    assert_uses(&plan, "reactions_user", "the reaction cleanup");
    assert_no_scan(&plan, "the reaction cleanup");
}

#[tokio::test]
async fn deleting_an_account_seeks_the_uploader_index() {
    let (pool, _guard) = new_pool("slimm-deletion-plan-uploaders").await;
    let source = deletion_source();
    let sql = support::query_literal_containing(
        &source,
        "DELETE FROM attachment_uploaders WHERE uploaded_by",
    );

    let plan = plan_of(&pool, &sql, 1).await;
    assert_uses(
        &plan,
        "attachment_uploaders_uploaded_by",
        "the uploader cleanup",
    );
    assert_no_scan(&plan, "the uploader cleanup");
}

#[tokio::test]
async fn deleting_an_account_seeks_the_overwrite_index() {
    let (pool, _guard) = new_pool("slimm-deletion-plan-overwrites").await;
    let source = deletion_source();
    let sql = support::query_literal_containing(
        &source,
        "DELETE FROM channel_overwrites WHERE target_type",
    );

    let plan = plan_of(&pool, &sql, 1).await;
    assert_uses(
        &plan,
        "channel_overwrites_target",
        "the member overwrite cleanup",
    );
    assert_no_scan(&plan, "the member overwrite cleanup");
}

/// The same index, reached by the other caller. Deleting a role clears its
/// overwrites through the identical shape, so narrowing the index to
/// `(target_id)` would have to fail here as well as above.
#[tokio::test]
async fn deleting_a_role_seeks_the_overwrite_index() {
    let (pool, _guard) = new_pool("slimm-deletion-plan-role-overwrites").await;
    let source = source_of("src/store/roles.rs");
    let sql = support::query_literal_containing(
        &source,
        "DELETE FROM channel_overwrites WHERE target_type",
    );

    let plan = plan_of(&pool, &sql, 1).await;
    assert_uses(
        &plan,
        "channel_overwrites_target",
        "the role overwrite cleanup",
    );
    assert_no_scan(&plan, "the role overwrite cleanup");
}

/// Not part of account deletion: `previously_visible_to` runs this on every
/// role-scoped overwrite edit, and the (user_id, role_id) primary key cannot
/// serve a bare `role_id` predicate.
#[tokio::test]
async fn listing_a_roles_members_seeks_the_member_roles_index() {
    let (pool, _guard) = new_pool("slimm-deletion-plan-member-roles").await;
    let source = source_of("src/store/roles.rs");
    let sql = support::query_literal_containing(&source, "FROM member_roles WHERE role_id");

    let plan = plan_of(&pool, &sql, 1).await;
    assert_uses(&plan, "member_roles_role", "the role member list");
    assert_no_scan(&plan, "the role member list");
}

/// The extraction's own guard, from a review that demonstrated the failure
/// against this file's first version: a comment quoting an older copy of the
/// query satisfied a bare search, so the real query could regress to a scan
/// with every test here still green.
#[test]
fn a_stale_comment_quoting_the_old_query_does_not_satisfy_the_gate() {
    let regressed = r#"
        // Formerly: "DELETE FROM reactions WHERE user_id = ?"
        sqlx::query!("DELETE FROM reactions WHERE hex(user_id) = hex(?)", user_id)
    "#;
    let found = std::panic::catch_unwind(|| {
        support::query_literal_containing(regressed, "DELETE FROM reactions WHERE user_id")
    });
    assert!(
        found.is_err(),
        "a comment is not code; the gate must refuse rather than validate the comment's SQL"
    );
}

/// The other half: a decoy comment must not shadow a query that is still real.
#[test]
fn the_live_query_is_read_past_a_comment_quoting_it() {
    let source = r#"
        // See "DELETE FROM reactions WHERE user_id = ?" below.
        sqlx::query!("DELETE FROM reactions WHERE user_id = ? AND emoji = ?", a, b)
    "#;
    assert_eq!(
        support::query_literal_containing(source, "DELETE FROM reactions WHERE user_id"),
        "DELETE FROM reactions WHERE user_id = ? AND emoji = ?"
    );
}

/// The moderation trail's own actor cleanup, which arrived with 0048.
///
/// Its index is partial (`WHERE actor_id IS NOT NULL`), so this checks more
/// than that some index exists: SQLite only uses a partial index when the
/// statement's own predicate implies the index's, and `actor_id = ?` does
/// imply `actor_id IS NOT NULL`. Widen the index, or narrow the statement, and
/// the plan silently falls back to scanning every act ever recorded.
#[tokio::test]
async fn deleting_an_account_seeks_the_moderation_audit_actor_index() {
    let (pool, _guard) = new_pool("slimm-deletion-plan-moderation").await;
    let source = deletion_source();
    let sql = support::query_literal_containing(
        &source,
        "UPDATE moderation_audit_log SET actor_id = NULL",
    );

    let plan = plan_of(&pool, &sql, 1).await;
    assert_uses(
        &plan,
        "moderation_audit_log_actor",
        "the audit actor cleanup",
    );
    assert_no_scan(&plan, "the audit actor cleanup");
}
