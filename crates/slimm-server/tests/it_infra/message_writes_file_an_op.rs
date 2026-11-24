// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Every write that changes what a client shows of a message files an op, or is
//! classified here with the reason it needs none. A new writer that does neither fails.

use std::path::Path;

use crate::support;

/// SQL that changes synced message state.
const WRITES: [&str; 4] = [
    "UPDATE messages SET",
    "DELETE FROM messages",
    "UPDATE message_forwards",
    "DELETE FROM message_forwards",
];

/// A function that writes message state without filing an op, and why that is fine.
const NO_OP_NEEDED: [(&str, &str, &str); 2] = [
    (
        "store/account_deletion/bounded.rs",
        "clear_message_authorship",
        "the author is never on the wire, and the content stays as it was",
    ),
    (
        "store/account_deletion/bounded.rs",
        "clear_authored_content",
        "a forward's origin author id is never on the wire either",
    ),
];

struct Site {
    file: String,
    function: String,
    body: String,
    code: String,
}

fn is_ident(c: char) -> bool {
    c.is_alphanumeric() || c == '_'
}

/// Position-preserving scrub of comments, strings and chars, so braces and `fn` are real code.
fn function_around(raw: &str, code: &str, at: usize) -> (String, String, String) {
    let start = code[..at]
        .match_indices("fn ")
        .filter(|(i, _)| !code[..*i].chars().next_back().is_some_and(is_ident))
        .last()
        .map(|(i, _)| i)
        .expect("a write outside any function");
    let name: String = code[start + 3..]
        .chars()
        .take_while(|c| is_ident(*c))
        .collect();
    let open = start + code[start..].find('{').expect("function body");
    let mut depth = 0usize;
    let mut end = open;
    for (i, c) in code[open..].char_indices() {
        match c {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if depth == 0 {
                    end = open + i;
                    break;
                }
            }
            _ => {}
        }
    }
    (
        name,
        raw[start..=end].to_owned(),
        code[start..=end].to_owned(),
    )
}

/// A call in real code, or the SQL literal; a comment that merely names `insert_message_op(` is neither.
fn files_an_op(code: &str, raw: &str) -> bool {
    code.contains("insert_message_op(") || raw.contains("INSERT INTO message_ops")
}

fn in_comment(raw: &str, at: usize) -> bool {
    let line_start = raw[..at].rfind('\n').map_or(0, |i| i + 1);
    raw[line_start..at].trim_start().starts_with("//")
}

fn write_sites(src: &Path) -> Vec<Site> {
    let mut sites = Vec::new();
    for path in support::rust_files_under(&src.join("store")) {
        let raw = std::fs::read_to_string(&path).expect("read source");
        let code = support::code_only(&raw);
        let file = path
            .strip_prefix(src)
            .unwrap()
            .to_string_lossy()
            .into_owned();
        for write in WRITES {
            for (at, _) in raw.match_indices(write) {
                if in_comment(&raw, at) {
                    continue;
                }
                let (function, body, code_body) = function_around(&raw, &code, at);
                sites.push(Site {
                    file: file.clone(),
                    function,
                    body,
                    code: code_body,
                });
            }
        }
    }
    sites
}

#[test]
fn every_message_write_files_an_op_or_is_classified() {
    let src = Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
    let sites = write_sites(&src);
    assert!(
        sites.len() >= 6,
        "the scan found only {} writes",
        sites.len()
    );
    let unclassified: Vec<String> = sites
        .iter()
        .filter(|site| {
            let files_op = files_an_op(&site.code, &site.body);
            let allowed = NO_OP_NEEDED
                .iter()
                .any(|(file, function, _)| *file == site.file && *function == site.function);
            !files_op && !allowed
        })
        .map(|site| format!("{}::{}", site.file, site.function))
        .collect();
    assert!(
        unclassified.is_empty(),
        "these write message state without filing an op; file one or classify them in NO_OP_NEEDED: {unclassified:?}"
    );
}

#[test]
fn the_classified_writers_still_exist() {
    let src = Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
    let sites = write_sites(&src);
    for (file, function, _) in NO_OP_NEEDED {
        assert!(
            sites
                .iter()
                .any(|site| site.file == file && site.function == function),
            "{file}::{function} no longer writes message state; drop it from NO_OP_NEEDED"
        );
    }
}

#[test]
fn a_comment_naming_the_op_call_does_not_count_as_filing_one() {
    let raw = "fn w() {\n    // no insert_message_op( needed\n    sqlx::query(\"UPDATE messages SET x\");\n}";
    assert!(!files_an_op(&support::code_only(raw), raw));
    let real = "fn w() {\n    insert_message_op(&mut tx);\n}";
    assert!(files_an_op(&support::code_only(real), real));
}
