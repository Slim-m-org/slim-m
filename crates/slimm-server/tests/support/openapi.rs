// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Shared route/schema extraction for `tests/openapi_contract.rs` and
//! `tests/openapi_429_coverage.rs`, so a route surface parser and a schema
//! parser exist exactly once between the two gates rather than as two
//! brace-scanners that can quietly diverge.
//!
//! Everything here is parsed straight out of source text rather than
//! trusted by inspection, for the reason `openapi_contract.rs`'s own module
//! doc gives: a schema that only has to be updated by someone remembering to
//! do it always rots.
//!
//! Allowed dead: `mod.rs` pulls this module into every integration test
//! binary via `mod support;`, and only the two gates named above ever touch
//! it, the same reason `support::wake_recipients` carries the same allow.
#![allow(dead_code)]

use std::fs;
use std::path::{Path, PathBuf};

// --- HTTP methods ---

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Method {
    Get,
    Post,
    Put,
    Patch,
    Delete,
    Head,
    Options,
    Trace,
}

impl Method {
    pub fn parse(word: &str) -> Option<Method> {
        Some(match word {
            "get" => Method::Get,
            "post" => Method::Post,
            "put" => Method::Put,
            "patch" => Method::Patch,
            "delete" => Method::Delete,
            "head" => Method::Head,
            "options" => Method::Options,
            "trace" => Method::Trace,
            _ => return None,
        })
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Method::Get => "GET",
            Method::Post => "POST",
            Method::Put => "PUT",
            Method::Patch => "PATCH",
            Method::Delete => "DELETE",
            Method::Head => "HEAD",
            Method::Options => "OPTIONS",
            Method::Trace => "TRACE",
        }
    }
}

const HTTP_VERBS: [&str; 8] = [
    "get", "post", "put", "patch", "delete", "head", "options", "trace",
];

/// A segment of an alphanumeric-plus-underscore identifier; used to make sure
/// a matched verb word is a whole token (`delete`) and not part of a longer
/// one (`delete_account`) or a preceding qualifier (`axum::routing::delete`
/// must still match, since `:` is not an identifier character).
pub fn is_ident_char(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b == b'_'
}

// --- Router-side extraction ---

#[derive(Debug, Clone)]
pub struct RouterRoute {
    pub method: Method,
    pub path: String,
    /// The bare identifier inside `get(<handler>)`/`post(<handler>)`/...;
    /// this codebase never qualifies a handler with its module path inline
    /// (it imports the name instead), only the verb itself is ever
    /// qualified (`axum::routing::delete(revoke)`).
    pub handler: String,
    pub file: String,
    pub line: usize,
}

/// Every `.route(` module under `src/http`, one file per HTTP surface area
/// plus the top-level `src/http.rs` (healthz, version). At least this many
/// files must contribute a route, or route discovery itself is broken (a
/// module went missing from disk, or the directory walk silently found
/// nothing).
const MIN_ROUTE_FILES: usize = 10;

/// Blanks `//` and `/* */` comments to spaces, keeping every byte's position
/// and every string literal's own content untouched, so [matching_close_paren]
/// never mistakes a comment's own `)` for the real end of a `.route(...)`
/// call - and [parse_route_call] still gets the real path bytes back out,
/// which blanking string content the way `tests/support::code_only` does
/// for pure brace-matching elsewhere would have destroyed.
///
/// A stray `)` inside a `/* ... */` comment sitting between two chained
/// methods - `get(list)/* also has a post handler ) */.post(create)` is
/// enough - closed [matching_close_paren]'s scan right there, silently
/// dropping every method after it from the extracted route while
/// `parse_route_call` still returned `Some` for what was left: a subset of
/// methods parses to a *wrong* answer, which this file's own found-vs-
/// parsed self-check cannot see either, since a parse still succeeded.
/// Reproduced directly: with `post: /categories` genuinely missing from
/// schema/openapi.yaml (a real drift) and this comment planted in the
/// route source, `openapi_matches_router` still passed.
pub fn strip_comments(source: &str) -> String {
    let bytes = source.as_bytes();
    let mut out = bytes.to_vec();
    let mut i = 0usize;
    let mut in_string = false;
    while i < bytes.len() {
        if in_string {
            if bytes[i] == b'\\' && i + 1 < bytes.len() {
                i += 2;
                continue;
            }
            if bytes[i] == b'"' {
                in_string = false;
            }
            i += 1;
            continue;
        }
        if bytes[i] == b'"' {
            in_string = true;
            i += 1;
            continue;
        }
        if bytes[i] == b'/' && bytes.get(i + 1) == Some(&b'/') {
            while i < bytes.len() && bytes[i] != b'\n' {
                out[i] = b' ';
                i += 1;
            }
            continue;
        }
        if bytes[i] == b'/' && bytes.get(i + 1) == Some(&b'*') {
            let mut k = i + 2;
            while k < bytes.len() && bytes.get(k..k + 2) != Some(b"*/") {
                k += 1;
            }
            let end = (k + 2).min(bytes.len());
            for idx in i..end {
                out[idx] = if bytes[idx] == b'\n' { b'\n' } else { b' ' };
            }
            i = end;
            continue;
        }
        i += 1;
    }
    String::from_utf8(out)
        .expect("comments were only ever replaced with ascii space/newline, so always valid utf-8")
}

pub fn matching_close_paren(bytes: &[u8], open: usize) -> Option<usize> {
    debug_assert_eq!(bytes[open], b'(');
    let mut depth = 0i32;
    for (i, &b) in bytes.iter().enumerate().skip(open) {
        match b {
            b'(' => depth += 1,
            b')' => {
                depth -= 1;
                if depth == 0 {
                    return Some(i);
                }
            }
            _ => {}
        }
    }
    None
}

/// Pulls the `(HTTP verb, handler ident)` pairs out of a route's handler
/// argument, e.g. `get(list).post(create)` or
/// `axum::routing::delete(revoke)`. Deliberately only scans the
/// handler-chain text, not the path string, so a path segment that happens
/// to contain a verb word (`/get-started`) can never be mistaken for a
/// method.
fn extract_method_handlers(chain: &str) -> Vec<(Method, String)> {
    let bytes = chain.as_bytes();
    let mut methods = Vec::new();
    for word in HTTP_VERBS {
        let mut from = 0usize;
        while let Some(rel) = chain[from..].find(word) {
            let start = from + rel;
            let end = start + word.len();
            let before_is_ident = start > 0 && is_ident_char(bytes[start - 1]);
            let after_is_ident = end < bytes.len() && is_ident_char(bytes[end]);
            if !before_is_ident && !after_is_ident {
                let mut j = end;
                while j < bytes.len() && bytes[j].is_ascii_whitespace() {
                    j += 1;
                }
                if j < bytes.len()
                    && bytes[j] == b'('
                    && let Some(close) = matching_close_paren(bytes, j)
                {
                    let handler = chain[j + 1..close].trim().to_owned();
                    methods.push((
                        Method::parse(word).expect("word is a known HTTP_VERBS entry"),
                        handler,
                    ));
                }
            }
            from = end;
        }
    }
    methods.sort_by_key(|a| a.0);
    methods.dedup_by(|a, b| a.0 == b.0);
    methods
}

/// Parses one `.route(` call's argument text (everything between its
/// parentheses) into the path literal and the `(method, handler)` pairs
/// bound to it. Returns `None` if the shape is not the expected
/// `"path", handler-chain`, which the caller treats as an extractor
/// failure, not as "this route has no methods".
fn parse_route_call(arg_text: &str) -> Option<(String, Vec<(Method, String)>)> {
    let after_open_quote = &arg_text[arg_text.find('"')? + 1..];
    let close_quote = after_open_quote.find('"')?;
    let path = after_open_quote[..close_quote].to_string();
    let methods = extract_method_handlers(&after_open_quote[close_quote + 1..]);
    if path.is_empty() || methods.is_empty() {
        return None;
    }
    Some((path, methods))
}

fn line_of(text: &str, byte_idx: usize) -> usize {
    text[..byte_idx].matches('\n').count() + 1
}

pub fn http_source_files(manifest_dir: &Path) -> Vec<PathBuf> {
    let mut files = vec![manifest_dir.join("src/http.rs")];
    let http_dir = manifest_dir.join("src/http");
    let mut submodules: Vec<PathBuf> = fs::read_dir(&http_dir)
        .unwrap_or_else(|e| panic!("cannot read {}: {e}", http_dir.display()))
        .map(|entry| entry.expect("readable dir entry").path())
        .filter(|p| p.extension().is_some_and(|ext| ext == "rs"))
        .collect();
    submodules.extend(family_files(&http_dir));
    submodules.sort();
    files.extend(submodules);
    files
}

/// Modules grouped under their parent, `http/canvas/canvas_ops.rs`: named with
/// the folder's prefix, unlike the nested routers some folders also hold.
fn family_files(http_dir: &Path) -> Vec<PathBuf> {
    let mut found = Vec::new();
    for dir in fs::read_dir(http_dir).into_iter().flatten().flatten() {
        let dir = dir.path();
        let Some(stem) = dir.file_name().and_then(|n| n.to_str()) else {
            continue;
        };
        if !dir.is_dir() {
            continue;
        }
        let plural = format!("{stem}_");
        let singular = format!("{}_", stem.strip_suffix('s').unwrap_or(stem));
        for file in fs::read_dir(&dir).into_iter().flatten().flatten() {
            let file = file.path();
            let named = file.file_name().and_then(|n| n.to_str()).unwrap_or("");
            if named.ends_with(".rs")
                && (named.starts_with(&plural) || named.starts_with(&singular))
            {
                found.push(file);
            }
        }
    }
    found
}

/// Extracts every `(method, path, handler)` the axum router actually
/// serves, from the source text of `src/http.rs` and `src/http/*.rs`.
///
/// Panics (rather than returning a partial result) if the self-check
/// described at the top of this file fails, since a gate that can silently
/// under-count routes is worse than no gate.
pub fn extract_router_routes(manifest_dir: &Path) -> Vec<RouterRoute> {
    let mut routes = Vec::new();
    let mut files_with_routes = 0usize;

    for file in http_source_files(manifest_dir) {
        let raw_source = fs::read_to_string(&file)
            .unwrap_or_else(|e| panic!("cannot read {}: {e}", file.display()));
        let text = strip_comments(&raw_source);
        let raw_call_sites = text.matches(".route(").count();
        if raw_call_sites == 0 {
            continue;
        }
        files_with_routes += 1;

        let bytes = text.as_bytes();
        let mut parsed_call_sites = 0usize;
        for (idx, _) in text.match_indices(".route(") {
            let open_paren = idx + ".route".len();
            let close_paren = matching_close_paren(bytes, open_paren).unwrap_or_else(|| {
                panic!(
                    "{}:{}: unbalanced parentheses reading a `.route(` call; \
                     the extractor in tests/support/openapi.rs cannot find where it ends",
                    file.display(),
                    line_of(&text, idx)
                )
            });
            let arg_text = &text[open_paren + 1..close_paren];
            let Some((path, methods)) = parse_route_call(arg_text) else {
                continue;
            };
            parsed_call_sites += 1;
            let line = line_of(&text, idx);
            let rel_file = file
                .strip_prefix(manifest_dir)
                .unwrap_or(&file)
                .to_string_lossy()
                .into_owned();
            for (method, handler) in methods {
                routes.push(RouterRoute {
                    method,
                    path: path.clone(),
                    handler: handler.clone(),
                    file: rel_file.clone(),
                    line,
                });
            }
        }

        // Self-check: found-vs-parsed must match, or the scanner regressed (see the module doc).
        assert_eq!(
            parsed_call_sites,
            raw_call_sites,
            "route extractor regression in {}: found {raw_call_sites} literal `.route(` call(s) \
             but only parsed {parsed_call_sites} of them into a path and methods; fix \
             parse_route_call/extract_method_handlers in tests/support/openapi.rs before \
             trusting this gate",
            file.display()
        );
    }

    assert!(
        !routes.is_empty(),
        "route extractor found zero routes anywhere under src/http; it is almost \
         certainly broken, not the codebase having no routes"
    );
    assert!(
        files_with_routes >= MIN_ROUTE_FILES,
        "route extractor only found `.route(` syntax in {files_with_routes} file(s) under \
         src/http, expected at least {MIN_ROUTE_FILES} (one per route module: http.rs plus \
         auth, channels, invites, messages, push, reactions, safety, sync, ws); either a route \
         module went missing or file discovery in tests/support/openapi.rs is broken"
    );

    routes
}

// --- Schema-side extraction ---

#[derive(Debug, Clone)]
pub struct SchemaRoute {
    pub method: Method,
    pub path: String,
    /// `None` when the operation block has no `operationId:` line at all,
    /// which the caller treats as a self-check failure rather than a route
    /// to silently drop.
    pub operation_id: Option<String>,
    /// Whether the operation's `responses:` block documents a `"429":` key.
    pub has_429: bool,
    pub line: usize,
}

/// Extracts every `(method, path)` documented under `paths:` in
/// schema/openapi.yaml, along with each operation's `operationId` and
/// whether it documents a `"429"` response.
///
/// This is a line-based reader tuned to this file's consistent 2-space
/// indent, not a general YAML parser: a path key sits at exactly two spaces
/// of indent (`  /channels:`), an HTTP-method key for it sits at exactly
/// four (`    get:`), sibling to things like `parameters:` that are ignored
/// because they are not one of the known verbs, and everything belonging to
/// that operation - `operationId:`, `responses:` and its status codes - sits
/// at six spaces or deeper until the next four-space-or-shallower line ends
/// the block.
pub fn extract_schema_routes(repo_root: &Path) -> Vec<SchemaRoute> {
    let schema_path = repo_root.join("schema/openapi.yaml");
    let text = fs::read_to_string(&schema_path)
        .unwrap_or_else(|e| panic!("cannot read {}: {e}", schema_path.display()));
    let lines: Vec<&str> = text.lines().collect();

    let mut routes = Vec::new();
    let mut in_paths = false;
    let mut current_path: Option<String> = None;

    let mut i = 0usize;
    while i < lines.len() {
        let raw_line = lines[i];
        let line_no = i + 1;
        if raw_line == "paths:" {
            in_paths = true;
            i += 1;
            continue;
        }
        if !in_paths {
            i += 1;
            continue;
        }
        if raw_line.trim().is_empty() {
            i += 1;
            continue;
        }
        // A line back at column 0 (`components:`) ends the `paths:` block.
        if !raw_line.starts_with(' ') {
            break;
        }

        let indent = raw_line.len() - raw_line.trim_start().len();
        let trimmed = raw_line.trim();

        if indent == 2 && trimmed.starts_with('/') && trimmed.ends_with(':') {
            current_path = Some(trimmed[..trimmed.len() - 1].to_string());
            i += 1;
            continue;
        }

        if indent == 4
            && let Some(key) = trimmed.strip_suffix(':')
            && !key.is_empty()
            && !key.contains(' ')
            && let Some(method) = Method::parse(key)
        {
            let path = current_path.clone().unwrap_or_else(|| {
                panic!(
                    "{}:{line_no}: found method `{key}:` with no enclosing path key above it",
                    schema_path.display()
                )
            });

            // Scan the operation's own block for its operationId and a documented "429".
            let mut operation_id = None;
            let mut has_429 = false;
            let mut j = i + 1;
            while j < lines.len() {
                let l = lines[j];
                if l.trim().is_empty() {
                    j += 1;
                    continue;
                }
                let ind = l.len() - l.trim_start().len();
                if ind <= 4 {
                    break;
                }
                let t = l.trim();
                if let Some(id) = t.strip_prefix("operationId:") {
                    operation_id = Some(id.trim().to_owned());
                } else if t == "\"429\":" {
                    has_429 = true;
                }
                j += 1;
            }

            routes.push(SchemaRoute {
                method,
                path,
                operation_id,
                has_429,
                line: line_no,
            });
            i = j;
            continue;
        }

        i += 1;
    }

    assert!(
        !routes.is_empty(),
        "schema route extractor found zero operations under `paths:` in {}; it is almost \
         certainly broken, not the schema having no paths",
        schema_path.display()
    );

    routes
}

// --- Comparison ---

/// Normalizes a path template so axum's `{channel_id}` and the schema's
/// `{channelId}` compare equal: both spell "one path parameter here", just
/// with a different naming convention for it. Every other segment (the
/// static parts of the path, and the number and order of segments) is
/// compared literally, so a genuinely different path still fails.
pub fn normalize(path: &str) -> String {
    path.split('/')
        .map(|segment| {
            if segment.starts_with('{') && segment.ends_with('}') && segment.len() >= 2 {
                "{}"
            } else {
                segment
            }
        })
        .collect::<Vec<_>>()
        .join("/")
}

/// `schema/openapi.yaml` as JSON, read as YAML 1.2: strict booleans keep a
/// bare `y` (the canvas coordinate in a `required` list) a string, where YAML
/// 1.1's `y`/`n`/`on`/`off` booleans would quietly turn it into `true`.
pub fn parse_schema_yaml(text: &str) -> serde_json::Value {
    serde_saphyr::from_str_with_options(text, serde_saphyr::options! { strict_booleans: true })
        .expect("schema/openapi.yaml parses as YAML")
}
