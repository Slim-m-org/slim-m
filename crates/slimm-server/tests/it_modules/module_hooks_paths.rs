// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Every path that stores words under someone's name runs
//! `module_hooks::guard_write` first, which asks the message.send permission
//! hook and runs the interceptor chain (decision 0100), or is listed here with
//! the reason it does not. A new path that stores a message without either
//! fails this test, so a filter or a posting ban cannot be bypassed by a route
//! nobody remembered.

use std::path::{Path, PathBuf};

use crate::support;
/// The store calls that write a message's words, and the http helpers that store embeds and buttons for their caller.
const WRITES: [&str; 14] = [
    ".send_message(",
    ".send_message_with_slow_mode(",
    ".send_module_message(",
    ".send_module_message_with_slow_mode(",
    ".edit_message(",
    ".send_poll_message(",
    ".send_app_message(",
    ".set_message_embeds(",
    ".replace_message_embeds(",
    ".set_message_components(",
    ".set_webhook_message_username(",
    "embeds::store_and_reload(",
    "embeds::after_edit(",
    "message_components::store_and_reload(",
];

const GUARD: &str = "guard_write(";

/// Files that write without [`GUARD`], the call they must still make, and why.
const EXEMPT: [(&str, Option<&str>, &str); 3] = [
    (
        "http/welcome.rs",
        None,
        "the welcome post is text an administrator wrote",
    ),
    (
        "http/embeds.rs",
        None,
        "it stores what its callers already guarded, and every caller is checked here",
    ),
    (
        "http/module_host.rs",
        Some("intercept("),
        "a module's post skips its own interceptors, and only a person's run asks the message.send hook",
    ),
];

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

/// The call the file at `rel` must make: [`GUARD`], or whatever its exemption names instead.
fn required_call(rel: &str) -> Option<&'static str> {
    match EXEMPT.iter().find(|(file, _, _)| *file == rel) {
        Some((_, instead, _)) => *instead,
        None => Some(GUARD),
    }
}

#[test]
fn every_path_that_stores_message_text_is_guarded_or_says_why_not() {
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
        if EXEMPT.iter().any(|(file, _, _)| *file == rel) {
            found_exempt.push(rel.clone());
        }
        if required_call(&rel).is_some_and(|call| !code.contains(call)) {
            unguarded.push(rel);
        }
    }
    assert!(
        unguarded.is_empty(),
        "these files store message text without module_hooks::guard_write: {unguarded:?}"
    );
    for (file, _, reason) in EXEMPT {
        assert!(
            found_exempt.iter().any(|f| f == file),
            "{file} no longer stores message text, so its exemption ({reason}) is stale"
        );
    }
}

#[test]
fn the_gate_can_fail() {
    let sneaky = "fn go() { state.store.send_poll_message(c, a).await; } // guard_write(";
    let code = support::code_only(sneaky);
    assert!(writes_text(&code));
    assert!(
        !code.contains(GUARD),
        "a comment naming the guard must not satisfy the gate"
    );
    assert_eq!(required_call("http/polls.rs"), Some(GUARD));
    assert_eq!(required_call("http/module_host.rs"), Some("intercept("));
    let honest =
        "fn go() { guard_write(&s, &d, &mut f).await?; embeds::after_edit(&s, c, m, r).await; }";
    let honest = support::code_only(honest);
    assert!(writes_text(&honest) && honest.contains(GUARD));
}
