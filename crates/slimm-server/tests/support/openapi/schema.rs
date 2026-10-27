// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Schema-side extraction: the documented routes parsed out of `schema/openapi.yaml`.

use std::fs;
use std::path::Path;

use super::Method;

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

/// Scans the operation block under `lines[at]` for its `operationId` and a documented "429".
///
/// Returns both, plus the index of the first line past the block.
fn scan_operation_block(lines: &[&str], at: usize) -> (Option<String>, bool, usize) {
    let mut operation_id = None;
    let mut has_429 = false;
    let mut j = at + 1;
    while j < lines.len() {
        let l = lines[j];
        if l.trim().is_empty() {
            j += 1;
            continue;
        }
        if l.len() - l.trim_start().len() <= 4 {
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
    (operation_id, has_429, j)
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

            let (operation_id, has_429, j) = scan_operation_block(&lines, i);
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
