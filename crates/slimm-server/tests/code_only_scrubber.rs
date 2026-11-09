// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `support::code_only`, the scrubber every source-reading gate trusts, blanks
//! what it must and leaves real code alone.
//!
//! A scrubber that mis-lexes a quote in a char literal opens a phantom string,
//! reads the next real string as code and the code after it as string, and
//! every gate scanning that file goes blind from there on without failing.
//!
//! The crate-level `dead_code` allow covers the shared `support` module: an
//! integration test is its own crate, so every helper this binary does not
//! call reads as unused.
#![allow(dead_code)]

use std::path::Path;

mod support;

use support::code_only;

#[test]
fn a_quote_in_a_char_literal_does_not_open_a_string() {
    let source = "fn f(c: char) -> &'static str {\n    match c { '\"' => \"&quot;\", _ => \"x\" }\n}\nasync fn after() { enforce(); }\n";
    let code = code_only(source);
    assert!(
        code.contains("async fn after() { enforce(); }"),
        "code after the literal was swallowed: {code:?}"
    );
    assert!(!code.contains("quot"), "the real string was read as code");
}

#[test]
fn a_quote_in_a_byte_literal_does_not_open_a_string() {
    let source = "if bytes[i] == b'\"' { push(\"a\"); }\nlet next = real_code();\n";
    let code = code_only(source);
    assert!(code.contains("real_code()"), "{code:?}");
    assert!(!code.contains("push(\"a\")"), "the string was read as code");
    assert!(code.contains("push("), "{code:?}");
}

#[test]
fn escaped_char_literals_end_where_they_close() {
    for literal in ["'\\''", "'\\\\'", "'\\n'", "'\\u{1F600}'", "'\\x41'", "'é'"] {
        let source = format!("let c = {literal}; let after = 1;");
        let code = code_only(&source);
        assert!(code.contains("let after = 1;"), "{literal}: {code:?}");
        assert!(!code.contains(literal), "{literal} was kept: {code:?}");
    }
}

#[test]
fn lifetimes_and_labels_are_code() {
    let source =
        "fn pick<'a>(x: &'a str, y: &'static str) -> &'a str { 'outer: loop { break 'outer; } x }";
    assert_eq!(code_only(source), source);
}

#[test]
fn a_char_literal_beside_a_lifetime_blanks_only_the_literal() {
    let source = "fn f<'a>(c: char, s: &'a str) { if c == '{' { g(s) } }";
    let code = code_only(source);
    assert!(code.contains("&'a str"), "{code:?}");
    assert_eq!(code.matches('{').count(), 2, "{code:?}");
}

#[test]
fn a_block_comment_nests() {
    let source = "/* outer /* inner */ still comment } */ real();";
    let code = code_only(source);
    assert!(code.contains("real();"), "{code:?}");
    assert!(!code.contains("still"), "{code:?}");
    assert!(!code.contains('}'), "{code:?}");
}

#[test]
fn positions_and_line_breaks_survive() {
    let source = "a(); // note\n/* one\ntwo */ b('\"', \"x\ny\");\n";
    let code = code_only(source);
    assert_eq!(code.len(), source.len());
    let breaks = |text: &str| {
        text.match_indices('\n')
            .map(|(at, _)| at)
            .collect::<Vec<_>>()
    };
    assert_eq!(breaks(&code), breaks(source));
}

/// Real Rust has balanced braces once comments, strings and char literals are gone.
///
/// The whole source tree is the oracle: one phantom string anywhere shows up as
/// an unbalanced file, including `invite_page.rs`, `link_preview/extract.rs` and
/// `media/names.rs`, whose quote char literals were the original failures.
#[test]
fn every_source_file_is_brace_balanced_after_scrubbing() {
    let src = Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
    let files = support::rust_files_under(&src);
    assert!(files.len() > 100, "only {} files under src", files.len());
    let mut skewed = Vec::new();
    for path in files {
        let code = code_only(&std::fs::read_to_string(&path).expect("read source"));
        for (open, close) in [('{', '}'), ('(', ')'), ('[', ']')] {
            if code.matches(open).count() != code.matches(close).count() {
                skewed.push(format!("{} ({open}{close})", path.display()));
            }
        }
    }
    assert!(
        skewed.is_empty(),
        "unbalanced after scrubbing, so the scrubber mis-lexed them:\n  {}",
        skewed.join("\n  ")
    );
}
