// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Every background task the crate can spawn is spawned by `run`.
//!
//! A sweep nobody starts compiles clean, passes its own pass-level tests and
//! simply never runs: the storage it reclaims grows until someone notices. The
//! pass tests call the `run_*_pass` wrappers directly and nothing else calls a
//! spawner, so this reads `run` itself rather than trusting a list kept by hand.
//!
//! The crate-level `dead_code` allow covers the shared `support` module: an
//! integration test is its own crate, so every helper this binary does not
//! call reads as unused.
#![allow(dead_code)]

use std::collections::BTreeMap;
use std::path::Path;

use crate::support;
/// Every `pub fn spawn_*` / `pub(crate) fn spawn_*` the crate defines, by name, with how many files define it.
///
/// Test helpers are private and the shared combinator takes generics, so
/// neither matches `fn spawn_name(`.
fn spawners(scrubbed_sources: &[String]) -> BTreeMap<String, usize> {
    let mut found = BTreeMap::new();
    for code in scrubbed_sources {
        for marker in ["pub fn ", "pub(crate) fn "] {
            for (at, _) in code.match_indices(marker) {
                let rest = &code[at + marker.len()..];
                let name: String = rest.chars().take_while(|c| is_ident(*c)).collect();
                if name.starts_with("spawn_") && rest[name.len()..].starts_with('(') {
                    *found.entry(name).or_insert(0) += 1;
                }
            }
        }
    }
    found
}

fn is_ident(c: char) -> bool {
    c.is_alphanumeric() || c == '_'
}

fn calls_of(body: &str, name: &str) -> usize {
    let call = format!("{name}(");
    body.match_indices(&call)
        .filter(|(at, _)| !body[..*at].chars().next_back().is_some_and(is_ident))
        .count()
}

fn read_scrubbed(path: &Path) -> String {
    support::code_only(&std::fs::read_to_string(path).expect("read source"))
}

#[test]
fn run_starts_every_background_task_the_crate_defines() {
    let src = Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
    let sources: Vec<String> = support::rust_files_under(&src)
        .iter()
        .map(|path| read_scrubbed(path))
        .collect();
    let defined = spawners(&sources);
    assert!(
        defined.len() >= 15,
        "found only {} spawners, expected the sweeps and monitors: {defined:?}",
        defined.len()
    );

    let lib = std::fs::read_to_string(src.join("lib.rs")).expect("read lib.rs");
    let run = support::function_body(&lib, "pub async fn run()");
    let missing: Vec<String> = defined
        .iter()
        .filter(|(name, files)| calls_of(&run, name) < **files)
        .map(|(name, files)| format!("{name} ({files} defined, {} called)", calls_of(&run, name)))
        .collect();
    assert!(
        missing.is_empty(),
        "`run` does not start these background tasks, so they never run:\n  {}",
        missing.join("\n  ")
    );
}

#[test]
fn the_detector_counts_a_dropped_spawn() {
    let sources = vec![
        "pub fn spawn_a_sweep(store: Store) {}\npub(crate) fn spawn_b_sweep() {}\n\
         pub(crate) fn spawn_sweep<F>(f: F) {}\nasync fn spawn_helper() {}"
            .to_owned(),
        "pub fn spawn_b_sweep() {}".to_owned(),
    ];
    let defined = spawners(&sources);
    assert_eq!(defined.get("spawn_a_sweep"), Some(&1));
    assert_eq!(defined.get("spawn_b_sweep"), Some(&2));
    assert_eq!(defined.len(), 2, "{defined:?}");

    let run = "a::spawn_a_sweep(x); let _ = b::spawn_b_sweep(); respawn_a_sweep(y);";
    assert_eq!(calls_of(run, "spawn_a_sweep"), 1);
    assert_eq!(
        calls_of(run, "spawn_b_sweep"),
        1,
        "one of the two is never called"
    );
}
