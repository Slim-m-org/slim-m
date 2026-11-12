// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Naming the attachment a search hit came through checks only the page of
//! messages it was given. `NOT IN (SELECT rowid FROM messages_fts ...)` built
//! the whole corpus's hit set first, doubling the full-text cost of a search
//! for a common word, so the plan is read out of the real query: the
//! messages' own text must be probed per candidate row, never materialised.

use std::fs;
use std::path::Path;

use sqlx::Row;

use crate::support;
/// The file without its comment lines, so a comment quoting an old query is never the one planned.
fn read_source(relative: &str) -> String {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join(relative);
    let text = fs::read_to_string(&path).unwrap_or_else(|_| panic!("read {relative}"));
    text.lines()
        .filter(|line| !line.trim_start().starts_with("//"))
        .collect::<Vec<_>>()
        .join("\n")
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

#[tokio::test]
async fn the_attachment_match_probes_message_text_per_row_instead_of_materialising_it() {
    let (_store, pool, _guard) = support::new_store_with_pool("slimm-attachment-text-plan").await;
    let source = read_source("src/store/attachment_text.rs");
    let template = plain_literal_containing(&source, "AND ma.message_id IN ({ids})");
    let sql = template.replace("{ids}", "?2, ?3");

    let plan: Vec<String> = sqlx::query(&format!("EXPLAIN QUERY PLAN {sql}"))
        .bind("hello")
        .bind(1_i64)
        .bind(2_i64)
        .fetch_all(&pool)
        .await
        .unwrap()
        .iter()
        .map(|row| row.get::<String, _>("detail"))
        .collect();

    let probes_per_row = plan
        .iter()
        .any(|step| step.contains("VIRTUAL TABLE INDEX 0:=M"));
    assert!(
        probes_per_row,
        "messages_fts is not probed by rowid; the plan is {plan:?}"
    );
    let materialises = plan
        .windows(2)
        .any(|pair| pair[0].contains("LIST SUBQUERY") && pair[1].contains("messages_fts"));
    assert!(
        !materialises,
        "a full-text hit set is built up front; the plan is {plan:?}"
    );
}
