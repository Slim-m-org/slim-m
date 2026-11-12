// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Every path that stores a member's text calls the interceptor chain first
//! (decision 0100), or is listed here with the reason it does not. A new path
//! that stores a message without either fails this test, so a filter cannot be
//! bypassed by a route nobody remembered.

use std::path::{Path, PathBuf};

use crate::support;
/// The store calls that create or rewrite a message's text.
const WRITES: [&str; 5] = [
    ".send_message(",
    ".send_message_with_slow_mode(",
    ".send_module_message(",
    ".send_module_message_with_slow_mode(",
    ".edit_message(",
];

/// Files that write message text without the chain, and why.
const EXEMPT: [(&str, &str); 1] = [(
    "http/welcome.rs",
    "the welcome post is text an administrator wrote",
)];

fn rust_files(dir: &Path, out: &mut Vec<PathBuf>) {
    for entry in std::fs::read_dir(dir).unwrap().flatten() {
        let path = entry.path();
        if path.is_dir() {
            rust_files(&path, out);
        } else if path.extension().is_some_and(|e| e == "rs") {
            out.push(path);
        }
    }
}

fn writes_text(code: &str) -> bool {
    WRITES.iter().any(|call| code.contains(call))
}

fn calls_chain(code: &str) -> bool {
    code.contains("intercept(")
}

#[test]
fn every_path_that_stores_message_text_runs_the_chain_or_says_why_not() {
    let src = Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
    let mut files = Vec::new();
    rust_files(&src.join("http"), &mut files);
    let mut unguarded = Vec::new();
    let mut found_exempt = Vec::new();
    for path in files {
        let rel = path
            .strip_prefix(&src)
            .unwrap()
            .to_string_lossy()
            .into_owned();
        let code = support::code_only(&std::fs::read_to_string(&path).unwrap());
        if !writes_text(&code) {
            continue;
        }
        if EXEMPT.iter().any(|(file, _)| *file == rel) {
            found_exempt.push(rel);
        } else if !calls_chain(&code) {
            unguarded.push(rel);
        }
    }
    assert!(
        unguarded.is_empty(),
        "these files store message text without module_hooks::intercept: {unguarded:?}"
    );
    for (file, reason) in EXEMPT {
        assert!(
            found_exempt.iter().any(|f| f == file),
            "{file} no longer stores message text, so its exemption ({reason}) is stale"
        );
    }
}

#[test]
fn the_gate_can_fail() {
    let sneaky = "fn go() { state.store.send_message(msg).await; } // intercept(";
    let code = support::code_only(sneaky);
    assert!(writes_text(&code));
    assert!(
        !calls_chain(&code),
        "a comment naming the chain must not satisfy the gate"
    );
    let honest = "fn go() { intercept(&state, &d).await?; state.store.edit_message(i).await; }";
    assert!(calls_chain(&support::code_only(honest)));
}
