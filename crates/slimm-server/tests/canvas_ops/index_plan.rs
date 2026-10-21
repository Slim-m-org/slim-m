// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `canvas_ops` had no index reaching `created_at` at all until migration
//! 0038, so the op-clock's restart seed and every pass of the sweep paid for
//! a full table scan under the database's one write lock. Left to itself on
//! a database nothing has ever `ANALYZE`d, SQLite can still pick a full scan
//! over an index that exists but is not selective enough to look worth using,
//! the same trap `canvas_index.rs`'s own R-Tree test exists for, so only the
//! plan itself can catch a regression here - the same reasoning that test
//! gives for reading its SQL out of source rather than a copy.

use std::fs;
use std::path::Path;

use sqlx::{Row, SqlitePool};

async fn new_pool(name: &str) -> (SqlitePool, crate::support::TestDbGuard) {
    let (path, guard) = crate::support::TestDbGuard::new(&format!("slimm-{name}"));
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

/// A whole string literal's body, given `anchor` - any unique substring
/// *inside* it, not necessarily its start. Searches backward from `anchor`
/// for the opening quote and forward for the matching close, so the caller
/// only has to name something distinctive about the query, the same way
/// `canvas_index.rs`'s `viewport_sql` locates the query it reads by a marker
/// rather than carrying a copy. `raw` picks `r#"`/`"#` over a plain `"`,
/// since these query bodies carry embedded `"column: Type"` annotations that
/// a bare `"` search would stop at early.
fn extract_containing(source: &str, anchor: &str, raw: bool) -> String {
    let pos = source
        .find(anchor)
        .unwrap_or_else(|| panic!("{anchor:?} no longer appears in the source"));
    let open = if raw { "r#\"" } else { "\"" };
    let start = source[..pos]
        .rfind(open)
        .unwrap_or_else(|| panic!("no opening quote before {anchor:?}"))
        + open.len();
    let close = if raw { "\"#" } else { "\"" };
    let end = source[pos..]
        .find(close)
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

/// `canvas_ops` is `WITHOUT ROWID`, so its own clustered primary-key b-tree
/// *is* the table - a full scan of it plans as `SEARCH canvas_ops USING
/// PRIMARY KEY` with no trailing constraint, not as `SCAN canvas_ops`, which
/// is why a plain `contains("SCAN")` check would have missed the very
/// regression this test exists to catch (confirmed by reverting migration
/// 0038 by hand: the unindexed seed plans exactly that way). A real seek
/// through the primary key always carries a parenthesized constraint list
/// after it, which is the one thing that tells the two apart.
///
/// Neither branch is gated on the string `canvas_ops` appearing in the step:
/// SQLite's plan names a scanned table by its query alias, not its real name
/// (`FROM canvas_ops o` scans as `SCAN o`), so that gate went blind on every
/// aliased query in this file - confirmed by isolating the remove pass alone
/// with migration 0038 reverted, which passed silently until the gate was
/// dropped. None of this file's queries have a legitimate scan of anything,
/// aliased or not, so neither branch needs a table name to stay precise.
fn assert_no_scan(plan: &[String], what: &str) {
    let scan = plan.iter().find(|step| {
        step.starts_with("SCAN") || (step.contains("USING PRIMARY KEY") && !step.contains('('))
    });
    assert!(
        scan.is_none(),
        "{what} fell back to a full scan; the plan is {plan:?}"
    );
}

/// `Store::now_ms_unique`'s seed, read straight from `canvas_op_clock.rs`.
/// A bare `MAX(created_at)` cannot use an index that leads with `kind`; this
/// is what proves the `WHERE kind IN (...)` rewrite is still there, not just
/// that the index migration shipped.
#[tokio::test]
async fn the_op_clock_seed_never_scans_canvas_ops() {
    let (pool, _guard) = new_pool("canvas-clock-plan").await;
    let source = read_source("src/store/canvas/canvas_op_clock.rs");
    let sql = extract_containing(&source, "WHERE kind IN ('place'", true);
    let plan = plan_of(&pool, &sql, &[]).await;
    assert_no_scan(&plan, "the op-clock seed");
}

/// The sweep's three passes, read straight from `canvas_ops_sweep.rs`. Each
/// is checked with a bind pair that matches zero rows (an empty database),
/// the exact shape that made the unindexed query expensive: nothing to find
/// early means reading every row before answering.
#[tokio::test]
async fn the_sweeps_three_passes_never_scan_canvas_ops() {
    let (pool, _guard) = new_pool("canvas-sweep-plan").await;
    let source = read_source("src/store/canvas/canvas_ops_sweep.rs");

    let restores = extract_containing(&source, "o.kind = 'restore'", true);
    let removes = extract_containing(&source, "o.kind = 'remove'", true);
    let clears = extract_containing(&source, "o.kind = 'clear'", true);

    assert_no_scan(
        &plan_of(&pool, &restores, &[0, 500]).await,
        "the restore pass",
    );
    assert_no_scan(
        &plan_of(&pool, &removes, &[0, 500]).await,
        "the remove pass",
    );
    assert_no_scan(&plan_of(&pool, &clears, &[0, 500]).await, "the clear pass");
}

/// The values between the first `(` and the next `)` after `anchor` - the
/// shape both `canvas_op_kind`'s `CHECK (kind IN (...))` and the seed's own
/// `WHERE kind IN (...)` share. None of the six kind values contain a `)` of
/// their own, so the first close paren after the list opens is always the
/// list's own end; a nested-paren list would need a depth counter, which
/// nothing here has ever needed.
fn extract_in_list(text: &str) -> Vec<String> {
    let open = text
        .find("IN (")
        .unwrap_or_else(|| panic!("no \"IN (\" in {text:?}"))
        + "IN (".len();
    let close = text[open..]
        .find(')')
        .unwrap_or_else(|| panic!("no closing ) after \"IN (\" in {text:?}"))
        + open;
    text[open..close]
        .split(',')
        .map(|s| s.trim().trim_matches('\'').to_owned())
        .collect()
}

/// `canvas_op_kind`'s own list of legal kinds, read from the live migrated
/// schema rather than scanned out of a migration file. 0034 and 0036 each
/// rebuilt `canvas_ops` to widen this CHECK constraint, and a future kind
/// rebuilds it again, so "read whichever migration currently defines it"
/// would need its own logic to find the right file among all of them - the
/// same kind of list that goes stale the moment somebody adds a kind and
/// forgets one place naming it, which is exactly what this test exists to
/// catch elsewhere. `sqlite_master.sql` needs none of that: it is SQLite's
/// own record of whichever `CREATE TABLE` last actually ran, so it is
/// authoritative by construction and self-updates across any future rebuild
/// with no file-discovery code here to go stale in step. `messages_rowid_alias.rs`
/// already reads a table's `sqlite_master.sql` the same way, for the same reason.
async fn canvas_op_kind_check_list(pool: &SqlitePool) -> Vec<String> {
    let sql: String =
        sqlx::query_scalar("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?")
            .bind("canvas_ops")
            .fetch_one(pool)
            .await
            .expect("canvas_ops is a real table in every migrated database");
    let anchor = sql.find("CONSTRAINT canvas_op_kind").unwrap_or_else(|| {
        panic!("canvas_op_kind no longer appears in canvas_ops's own schema: {sql}")
    });
    extract_in_list(&sql[anchor..])
}

/// The op-clock seed's `WHERE kind IN (...)` list against `canvas_op_kind`'s
/// own CHECK constraint. A kind present in one and not the other is exactly
/// the miss a seventh canvas review named: a future kind added to the CHECK
/// constraint and to `canvas_ops.rs`'s own read-path match (which fails
/// loudly, on that kind's first read, via its `anyhow::bail!`) without also
/// being added to the seed's own list here, which fails silently - a stale
/// restart seed narrows the same timestamp-uniqueness fence
/// `now_ms_unique`'s own doc already names as its residual risk.
#[tokio::test]
async fn the_op_clock_seed_names_every_kind_the_check_constraint_allows() {
    let (pool, _guard) = new_pool("canvas-clock-kinds").await;
    let source = read_source("src/store/canvas/canvas_op_clock.rs");
    let seed_sql = extract_containing(&source, "WHERE kind IN ('place'", true);

    let mut seeded = extract_in_list(&seed_sql);
    let mut allowed = canvas_op_kind_check_list(&pool).await;
    seeded.sort();
    allowed.sort();

    assert_eq!(
        seeded, allowed,
        "the op-clock seed's kind list has drifted from canvas_op_kind's own CHECK constraint"
    );
}
