// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Gates schema/openapi.yaml's `"429"` response against which routes really
//! charge the rate limiter, so a handler that starts charging cannot stay
//! undocumented the way most of the surface already had before this gate:
//! only 52 of 115 operations named `TooManyRequests` even though a handler's
//! own signature already says whether it charges.
//!
//! A handler charges iff its signature takes a `RateLimited<C>` or
//! `AuthedLimited<C>` extractor, or its body calls `enforce(`. That is
//! exactly the convention `http/extract.rs`'s own doc comments describe, and
//! the same rule `tests/rate_limit_coverage.rs` already enforces for a
//! related but distinct invariant (every `Authed`-only handler is a bug); this
//! gate is about the *documentation* of a charge that already exists, not
//! about whether a charge should exist.
//!
//! Reuses `tests/support/openapi.rs`'s router/schema scanners rather than
//! re-parsing `.route(...)` calls or `paths:` a second time; the only new
//! parsing here is resolving a route's handler ident to the function that
//! defines it (searching the route's own file, then following a
//! `use super::module::name;` import when the handler lives in a sibling
//! module), and reading that function's charge shape out of
//! `support::code_only`'s comment-and-string-stripped text.

#![allow(dead_code)]

use std::collections::BTreeMap;
use std::path::Path;

mod support;

use support::code_only;
use support::openapi::{
    Method, RouterRoute, SchemaRoute, extract_router_routes, extract_schema_routes,
    http_source_files, matching_close_paren, normalize,
};

/// One `fn`/`async fn` definition found in a comment/string-stripped source
/// file: its parameter-list signature (from the `fn` keyword through the
/// closing paren) and its body (the `{...}` block that follows). A handler
/// always has a body; an empty one here would mean a semicolon-terminated
/// declaration, which never applies to a route handler.
struct HandlerFn {
    signature: String,
    body: String,
}

/// Every top-level `fn`/`async fn` definition in `scrubbed`, keyed by name.
/// Operates on already comment/string-stripped text (via [support::code_only])
/// so a doc comment or string literal that merely mentions `fn foo(` can
/// never be read as a definition.
fn functions_in(scrubbed: &str) -> BTreeMap<String, HandlerFn> {
    let bytes = scrubbed.as_bytes();
    let mut out = BTreeMap::new();
    for (idx, _) in scrubbed.match_indices("fn ") {
        if idx > 0 && support::openapi::is_ident_char(bytes[idx - 1]) {
            continue;
        }
        // A `fn` at brace depth above zero sits in an impl or mod block, so it is a method or private helper, never a route handler.
        if scrubbed[..idx].bytes().filter(|&b| b == b'{').count()
            != scrubbed[..idx].bytes().filter(|&b| b == b'}').count()
        {
            continue;
        }
        let name_start = idx + "fn ".len();
        let mut i = name_start;
        while i < bytes.len() && support::openapi::is_ident_char(bytes[i]) {
            i += 1;
        }
        if i == name_start {
            continue;
        }
        let name = scrubbed[name_start..i].to_owned();
        let mut paren_search = i;
        while paren_search < bytes.len()
            && bytes[paren_search] != b'('
            && bytes[paren_search] != b';'
            && bytes[paren_search] != b'{'
        {
            paren_search += 1;
        }
        if paren_search >= bytes.len() || bytes[paren_search] != b'(' {
            continue;
        }
        let Some(close_paren) = matching_close_paren(bytes, paren_search) else {
            continue;
        };
        let signature = scrubbed[idx..=close_paren].to_owned();
        let mut j = close_paren + 1;
        while j < bytes.len() && bytes[j] != b'{' && bytes[j] != b';' {
            j += 1;
        }
        let body = if j < bytes.len() && bytes[j] == b'{' {
            let mut depth = 0i32;
            let start = j;
            let mut end = None;
            let mut k = j;
            while k < bytes.len() {
                match bytes[k] {
                    b'{' => depth += 1,
                    b'}' => {
                        depth -= 1;
                        if depth == 0 {
                            end = Some(k);
                            break;
                        }
                    }
                    _ => {}
                }
                k += 1;
            }
            end.map_or_else(String::new, |e| scrubbed[start..=e].to_owned())
        } else {
            String::new()
        };
        if out
            .insert(name.clone(), HandlerFn { signature, body })
            .is_some()
        {
            panic!(
                "two top-level fn `{name}` in one source file: handler resolution cannot disambiguate them"
            );
        }
    }
    out
}

/// The sibling module a `use super::<module>::<name>;` (or the grouped form
/// `use super::<module>::{a, name, b};`) imports `name` from, if any.
fn imported_from(scrubbed: &str, name: &str) -> Option<String> {
    let mut from = 0usize;
    while let Some(rel) = scrubbed[from..].find("use super::") {
        let start = from + rel + "use super::".len();
        let Some(semi_rel) = scrubbed[start..].find(';') else {
            break;
        };
        let clause = &scrubbed[start..start + semi_rel];
        from = start + semi_rel + 1;
        let Some((module, rest)) = clause.split_once("::") else {
            continue;
        };
        let items = rest.trim().trim_start_matches('{').trim_end_matches('}');
        for item in items.split(',') {
            let item = item.trim().split(" as ").next().unwrap_or("").trim();
            if item == name {
                return Some(module.trim().to_owned());
            }
        }
    }
    None
}

/// Resolves a router route's handler ident to the function that defines it:
/// first in the route's own file, then - if the file only imports the name -
/// in the sibling `http/<module>.rs` the `use super::<module>::<name>;`
/// names. `None` means neither found it, which the caller treats as a
/// self-check failure rather than a route to silently skip.
fn resolve_handler(manifest_dir: &Path, route: &RouterRoute) -> Option<(String, HandlerFn)> {
    let route_path = manifest_dir.join(&route.file);
    let route_source = std::fs::read_to_string(&route_path).ok()?;
    let scrubbed = code_only(&route_source);
    if let Some(f) = functions_in(&scrubbed).remove(&route.handler) {
        return Some((route.file.clone(), f));
    }
    // A path-qualified handler such as `version::version` names its module outright.
    let (module, name) = match route.handler.split_once("::") {
        Some((module, name)) => (module.to_owned(), name.to_owned()),
        None => (
            imported_from(&scrubbed, &route.handler)?,
            route.handler.clone(),
        ),
    };
    let target_rel = format!("src/http/{module}.rs");
    let target_source = std::fs::read_to_string(manifest_dir.join(&target_rel)).ok()?;
    let target_scrubbed = code_only(&target_source);
    let f = functions_in(&target_scrubbed).remove(&name)?;
    Some((target_rel, f))
}

/// The exact charge rule this gate enforces: a `RateLimited<C>` or
/// `AuthedLimited<C>` extractor in the signature, or an `enforce(` call in
/// the body.
fn charges(handler: &HandlerFn) -> bool {
    handler.signature.contains("RateLimited<")
        || handler.signature.contains("AuthedLimited<")
        || handler.body.contains("enforce(")
}

/// One resolved router route paired with its charge verdict, built once and
/// shared by both directions of the comparison below.
struct Resolved<'a> {
    route: &'a RouterRoute,
    charges: bool,
}

fn resolve_all<'a>(manifest_dir: &Path, routes: &'a [RouterRoute]) -> Vec<Resolved<'a>> {
    routes
        .iter()
        .map(|route| {
            let (_def_file, handler) = resolve_handler(manifest_dir, route).unwrap_or_else(|| {
                panic!(
                    "{} {} ({}:{}): handler `{}` could not be resolved to a function \
                     definition in src/http.rs or src/http/*.rs, either locally or via a \
                     `use super::<module>::{};` import; fix resolve_handler in \
                     tests/openapi_429_coverage.rs before trusting this gate",
                    route.method.as_str(),
                    route.path,
                    route.file,
                    route.line,
                    route.handler,
                    route.handler
                )
            });
            Resolved {
                route,
                charges: charges(&handler),
            }
        })
        .collect()
}

/// The schema operation matching `route`, by normalized `(method, path)`.
/// Panics naming the route if there is not exactly one match, since either
/// zero or more than one means `openapi_matches_router` itself is failing to
/// notice something this gate should not paper over.
fn schema_match<'a>(route: &RouterRoute, schema_routes: &'a [SchemaRoute]) -> &'a SchemaRoute {
    let key = (route.method, normalize(&route.path));
    let matches: Vec<&SchemaRoute> = schema_routes
        .iter()
        .filter(|s| (s.method, normalize(&s.path)) == key)
        .collect();
    match matches.as_slice() {
        [one] => one,
        [] => panic!(
            "{} {} ({}:{}) has no matching operation in schema/openapi.yaml; \
             openapi_matches_router should already fail this",
            route.method.as_str(),
            route.path,
            route.file,
            route.line
        ),
        many => panic!(
            "{} {} ({}:{}) matches {} operations in schema/openapi.yaml, expected exactly one",
            route.method.as_str(),
            route.path,
            route.file,
            route.line,
            many.len()
        ),
    }
}

/// The reverse direction (documented `"429"` but the handler does not
/// charge) is asserted as a hard failure, not just reported: every
/// documented `"429"` in this schema was checked at the time this gate was
/// written to belong to a route that genuinely charges by this file's rule,
/// so a new mismatch is drift rather than a transitive-charge case the rule
/// misses.
#[test]
fn charging_routes_document_429() {
    let manifest_dir = Path::new(env!("CARGO_MANIFEST_DIR"));
    let repo_root = manifest_dir
        .parent()
        .and_then(Path::parent)
        .expect("crates/slimm-server is two directories below the repo root");

    let router_routes = extract_router_routes(manifest_dir);
    let schema_routes = extract_schema_routes(repo_root);
    let resolved = resolve_all(manifest_dir, &router_routes);

    let mut missing_429 = Vec::new();
    let mut reverse_findings = Vec::new();

    for r in &resolved {
        let schema_route = schema_match(r.route, &schema_routes);
        let operation_id = schema_route.operation_id.as_deref().unwrap_or_else(|| {
            panic!(
                "{} {} (schema/openapi.yaml:{}) has no operationId; every operation must \
                 have one for this gate to name it",
                r.route.method.as_str(),
                r.route.path,
                schema_route.line
            )
        });
        if r.charges && !schema_route.has_429 {
            missing_429.push(format!(
                "{} {} (operationId {operation_id}, handler `{}` in {}:{}) charges a rate \
                 limit but schema/openapi.yaml:{} does not document \"429\"",
                r.route.method.as_str(),
                r.route.path,
                r.route.handler,
                r.route.file,
                r.route.line,
                schema_route.line
            ));
        }
        if !r.charges && schema_route.has_429 {
            reverse_findings.push(format!(
                "{} {} (operationId {operation_id}, handler `{}` in {}:{}) documents \"429\" \
                 at schema/openapi.yaml:{} but its handler does not charge by this gate's rule",
                r.route.method.as_str(),
                r.route.path,
                r.route.handler,
                r.route.file,
                r.route.line,
                schema_route.line
            ));
        }
    }

    missing_429.sort();
    missing_429.dedup();
    assert!(
        missing_429.is_empty(),
        "\nthese routes charge a rate-limit class but schema/openapi.yaml has no \"429\" for \
         them:\n\n{}\n",
        missing_429.join("\n")
    );

    reverse_findings.sort();
    reverse_findings.dedup();
    assert!(
        reverse_findings.is_empty(),
        "\nthese operations document \"429\" but their handler does not charge by this gate's \
         rule (RateLimited<C>/AuthedLimited<C> in the signature, or an enforce( call in the \
         body):\n\n{}\n",
        reverse_findings.join("\n")
    );
}

/// The gate must be able to tell all three charge shapes apart, or it proves
/// nothing. Mirrors `tests/rate_limit_coverage.rs`'s own sample-based checks
/// for the same reason: a detector's positive and negative cases both need
/// direct proof, not just a green run over real source that might pass by
/// coincidence.
#[test]
fn charges_recognizes_all_three_shapes_and_rejects_a_comment() {
    let sample = r#"
async fn charged_by_rate_limited(
    _limited: RateLimited<READ>,
    State(state): State<AppState>,
) -> Result<(), ApiError> { Ok(()) }

async fn charged_by_authed_limited(
    AuthedLimited(ctx): AuthedLimited<WRITE>,
) -> Result<(), ApiError> { Ok(()) }

async fn charged_by_enforce_call(
    Authed(ctx): Authed,
    State(state): State<AppState>,
    parts: Parts,
) -> Result<(), ApiError> { enforce(&state, &parts, Some(&ctx), Class::Write)?; Ok(()) }

/// This handler would call enforce(...) if it charged anything, which it does not.
async fn charges_nothing(
    Authed(ctx): Authed,
) -> Result<(), ApiError> { Ok(()) }
"#;
    let scrubbed = code_only(sample);
    let fns = functions_in(&scrubbed);
    assert_eq!(
        fns.len(),
        4,
        "expected all four sample handlers to be found"
    );

    assert!(charges(&fns["charged_by_rate_limited"]));
    assert!(charges(&fns["charged_by_authed_limited"]));
    assert!(charges(&fns["charged_by_enforce_call"]));
    assert!(
        !charges(&fns["charges_nothing"]),
        "a doc comment naming enforce(...) must not read as a charge"
    );
}

/// `resolve_handler` must follow a `use super::<module>::<name>;` import to
/// the sibling file that actually defines the handler, since this codebase's
/// most common handler names (`list`, `create`, `update`, `delete`, ...) are
/// reused across many `http/*.rs` modules and a name-only search would
/// silently resolve to the wrong one.
#[test]
fn resolve_handler_follows_a_cross_module_import() {
    let manifest_dir = Path::new(env!("CARGO_MANIFEST_DIR"));
    let route = RouterRoute {
        method: Method::Post,
        path: "/channels/{channel_id}/canvas/objects".to_owned(),
        handler: "place".to_owned(),
        file: "src/http/canvas.rs".to_owned(),
        line: 0,
    };
    let (def_file, handler) =
        resolve_handler(manifest_dir, &route).expect("place resolves via canvas_write.rs");
    assert_eq!(def_file, "src/http/canvas_write.rs");
    assert!(
        charges(&handler),
        "placeCanvasObject is expected to charge CANVAS"
    );
}

#[test]
fn resolve_handler_follows_a_module_qualified_handler() {
    let manifest_dir = Path::new(env!("CARGO_MANIFEST_DIR"));
    let route = RouterRoute {
        method: Method::Get,
        path: "/version".to_owned(),
        handler: "version::version".to_owned(),
        file: "src/http.rs".to_owned(),
        line: 0,
    };
    let (def_file, handler) =
        resolve_handler(manifest_dir, &route).expect("version resolves via http/version.rs");
    assert_eq!(def_file, "src/http/version.rs");
    assert!(charges(&handler), "/version is expected to charge READ");
}

/// `http_source_files` backs both this gate and `extract_router_routes`;
/// proving it still finds real files here catches a path typo without
/// waiting for the harder-to-read failure the main test would give instead.
#[test]
fn http_source_files_finds_real_files() {
    let manifest_dir = Path::new(env!("CARGO_MANIFEST_DIR"));
    let files = http_source_files(manifest_dir);
    assert!(files.iter().any(|f| f.ends_with("canvas_write.rs")));
    assert!(files.iter().all(|f| f.exists()));
}
