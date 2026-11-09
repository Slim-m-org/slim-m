// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Every authenticated route charges a rate-limit class, proven against the
//! router's own source rather than a list kept by hand.
//!
//! `http/extract.rs`'s own doc comment already says why the `AuthedLimited`
//! extractor exists: declaring the class in the signature "makes 'no limit' a
//! visible, reviewable choice instead of an absence". That made an omission
//! reviewable; it never made one impossible, because a handler taking plain
//! `Authed` still compiles and still charges nothing. This project has
//! already paid for that gap once - CLAUDE.md records eight routes charging
//! nothing, found by an audit rather than by CI - and it recurred on the read
//! side, where seventeen authenticated GETs went uncharged, including one
//! serving whole attachment files off disk.
//!
//! So the convention is enforced here instead of trusted. A handler is
//! charged if it either takes an `AuthedLimited<C>` extractor or calls
//! `enforce` itself; anything else fails this test by name.
//!
//! Reads the real source through `support::code_only`, so a comment or a
//! string literal mentioning `enforce` cannot satisfy the gate - the exact
//! defect PR #553 found in eleven other source-reading gates in this repo.
//!
//! The crate-level `dead_code` allow covers the shared `support` module: an
//! integration test is its own crate, so every helper this binary does not
//! call reads as unused, and this one wants only the scrubber.
#![allow(dead_code)]

use std::collections::BTreeSet;
use std::path::Path;

mod support;

/// Fewer than this many files under `src/http` means the walk stopped short.
const MIN_HTTP_FILES: usize = 100;

/// Every `.rs` file under `src/http`, nested route families included, as
/// (path relative to `src/http`, comment- and string-scrubbed source).
fn http_sources() -> Vec<(String, String)> {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("src/http");
    support::rust_files_under(&root)
        .into_iter()
        .map(|path| {
            let rel = path.strip_prefix(&root).expect("under src/http");
            let source = std::fs::read_to_string(&path).expect("read source");
            (
                rel.to_string_lossy().into_owned(),
                support::code_only(&source),
            )
        })
        .collect()
}

/// Handlers deliberately left uncharged, each with the reason it is safe.
///
/// Empty on purpose: the sweep that built this gate found no authenticated
/// handler that genuinely should charge nothing. An entry here needs a real
/// argument, not a note that adding the extractor was inconvenient.
const EXEMPT: &[(&str, &str)] = &[];

/// A handler's own source, from its `async fn` line to the start of the next
/// one, with comments and string literals already blanked.
fn handlers(scrubbed: &str) -> Vec<(String, String)> {
    let mut found = Vec::new();
    let mut starts: Vec<usize> = Vec::new();
    for (idx, _) in scrubbed.match_indices("async fn ") {
        starts.push(idx);
    }
    for (i, &start) in starts.iter().enumerate() {
        let end = starts.get(i + 1).copied().unwrap_or(scrubbed.len());
        let body = &scrubbed[start..end];
        let name: String = body["async fn ".len()..]
            .chars()
            .take_while(|c| c.is_alphanumeric() || *c == '_')
            .collect();
        if !name.is_empty() {
            found.push((name, body.to_owned()));
        }
    }
    found
}

/// Everything before the closing paren of the parameter list, which is where
/// an extractor is declared; a body mentioning `Authed` in a local binding
/// must not read as one.
fn signature(body: &str) -> &str {
    match body.find("\n) ") {
        Some(end) => &body[..end],
        None => body,
    }
}

#[test]
fn every_authenticated_handler_charges_a_rate_limit_class() {
    let exempt: BTreeSet<&str> = EXEMPT.iter().map(|(name, _)| *name).collect();
    let mut uncharged = Vec::new();

    for (file, scrubbed) in http_sources() {
        for (name, body) in handlers(&scrubbed) {
            let sig = signature(&body);
            let takes_authed = sig.contains(": Authed,") || sig.contains(": Authed)");
            let limited = sig.contains(": AuthedLimited<");
            let charged = body.contains("enforce(");
            let label = format!("{file}::{name}");
            if takes_authed && !limited && !charged && !exempt.contains(label.as_str()) {
                uncharged.push(label);
            }
        }
    }

    assert!(
        uncharged.is_empty(),
        "these authenticated handlers charge no rate limit; take an \
         AuthedLimited<CLASS> extractor, call enforce, or add an EXEMPT entry \
         saying why none is needed:\n  {}",
        uncharged.join("\n  ")
    );
}

/// `Class::Read` exists for unauthenticated metadata (`/version`) and is
/// tighter on purpose than every authenticated read class - see its own doc
/// comment in `ratelimit/class.rs`. An authenticated handler charging it
/// anyway is exactly the API1 defect this test set closes: analytics and
/// metrics fought `/version`'s own callers for a budget sized for a login
/// screen, and the roster, `/space/settings`, and `/members/removed` shared
/// a mutation budget on the other class instead of landing here.
///
/// A handler is flagged if it takes `AuthedLimited<READ>` (the old, wrong
/// code - authenticated call sites now take `AuthedLimited<AUTHED_READ>`) or
/// calls `enforce(..., Class::Read)` while also authenticating the caller.
#[test]
fn no_authenticated_handler_charges_class_read() {
    let mut offenders = Vec::new();

    for (file, scrubbed) in http_sources() {
        for (name, body) in handlers(&scrubbed) {
            let sig = signature(&body);
            let takes_authed = sig.contains(": Authed,")
                || sig.contains(": Authed)")
                || sig.contains(": AuthedLimited<");
            if !takes_authed {
                continue;
            }
            let charges_read =
                sig.contains(": AuthedLimited<READ>") || body.contains("Class::Read)");
            if charges_read {
                offenders.push(format!("{file}::{name}"));
            }
        }
    }

    assert!(
        offenders.is_empty(),
        "these authenticated handlers charge Class::Read, which is reserved for \
         unauthenticated metadata like /version; use AuthedLimited<AUTHED_READ> \
         for a cheap read, or Class::Write if the route does real work:\n  {}",
        offenders.join("\n  ")
    );
}

/// The gate above must be able to fail, or it proves nothing - the same
/// argument [`the_gate_sees_an_uncharged_handler`] already makes for the
/// coverage gate. Drives it over one handler still on the extractor code and
/// one still on the literal enforce call, and asserts both are caught.
#[test]
fn the_read_class_gate_sees_both_charge_shapes() {
    let sample = r#"
async fn charged_by_old_extractor(
    AuthedLimited(ctx): AuthedLimited<READ>,
) -> Result<(), ApiError> { Ok(()) }

async fn charged_by_literal_enforce(
    Authed(ctx): Authed,
) -> Result<(), ApiError> { enforce(&state, &parts, Some(&ctx), Class::Read)?; Ok(()) }

async fn charged_correctly(
    AuthedLimited(ctx): AuthedLimited<AUTHED_READ>,
) -> Result<(), ApiError> { Ok(()) }
"#;
    let scrubbed = support::code_only(sample);
    let seen: Vec<String> = handlers(&scrubbed)
        .into_iter()
        .filter(|(_, body)| {
            let sig = signature(body);
            let takes_authed = sig.contains(": Authed,")
                || sig.contains(": Authed)")
                || sig.contains(": AuthedLimited<");
            takes_authed && (sig.contains(": AuthedLimited<READ>") || body.contains("Class::Read)"))
        })
        .map(|(name, _)| name)
        .collect();
    assert_eq!(
        seen,
        vec![
            "charged_by_old_extractor".to_owned(),
            "charged_by_literal_enforce".to_owned(),
        ],
        "the detector must catch exactly the two handlers still on Class::Read"
    );
}

/// The gate must be able to fail, or it proves nothing.
///
/// A gate over source text passes trivially if its own matching is broken -
/// the failure mode CLAUDE.md records for the label guard, which went green
/// while the thing it named was gone. This drives the detector over a handler
/// that is genuinely uncharged and asserts it is seen.
#[test]
fn the_gate_sees_an_uncharged_handler() {
    let sample = r#"
async fn charged_by_extractor(
    AuthedLimited(ctx): AuthedLimited<READ>,
) -> Result<(), ApiError> { Ok(()) }

async fn charged_by_enforce(
    Authed(ctx): Authed,
) -> Result<(), ApiError> { enforce(&state, &parts, Some(&ctx), Class::Write)?; Ok(()) }

async fn charges_nothing(
    Authed(ctx): Authed,
) -> Result<(), ApiError> { Ok(()) }
"#;
    let scrubbed = support::code_only(sample);
    let seen: Vec<String> = handlers(&scrubbed)
        .into_iter()
        .filter(|(_, body)| {
            let sig = signature(body);
            (sig.contains(": Authed,") || sig.contains(": Authed)"))
                && !sig.contains(": AuthedLimited<")
                && !body.contains("enforce(")
        })
        .map(|(name, _)| name)
        .collect();
    assert_eq!(
        seen,
        vec!["charges_nothing".to_owned()],
        "the detector must catch exactly the uncharged handler"
    );
}

/// A comment must not be able to satisfy the gate.
///
/// The defect PR #553 found in eleven gates at once: a doc comment describing
/// the very call it claims to make satisfies a naive substring scan, so the
/// gate goes green over a handler that charges nothing.
#[test]
fn a_comment_mentioning_enforce_does_not_satisfy_the_gate() {
    let sample = r#"
/// This handler would call enforce(...) if it charged anything, which it does not.
async fn charges_nothing(
    Authed(ctx): Authed,
) -> Result<(), ApiError> { Ok(()) }
"#;
    let scrubbed = support::code_only(sample);
    let (_, body) = handlers(&scrubbed).pop().expect("one handler");
    assert!(
        !body.contains("enforce("),
        "a comment naming enforce must not read as a charge"
    );
}

/// Both gates above read through [`http_sources`]; a walk that skipped the
/// route-family folders would leave them green over most of the handlers.
#[test]
fn the_gates_read_the_nested_route_families() {
    let sources = http_sources();
    assert!(
        sources.len() >= MIN_HTTP_FILES,
        "scanned {} files under src/http, expected at least {MIN_HTTP_FILES}",
        sources.len()
    );
    let nested_authed = sources
        .iter()
        .filter(|(file, scrubbed)| file.contains('/') && scrubbed.contains(": Authed"))
        .count();
    assert!(
        nested_authed > 0,
        "no nested file taking Authed was scanned; the walk skips subdirectories"
    );
}
