// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Extension-point name rules: what a client can route, and what may not repeat.

use super::{ManifestError, ManifestExtensionPoint, malformed};

/// Matches `module_commands::MAX_COMMAND_LEN`, the route's own ceiling.
const MAX_KEYWORD_BYTES: usize = 64;

/// Kinds whose `name` is typed or routed rather than shown, so it must be one token.
fn is_keyword_kind(kind: &str) -> bool {
    matches!(kind, "command" | "slash-command")
}

/// Kinds a client resolves by name, so two of them under one name are ambiguous.
fn is_resolved_by_name(kind: &str) -> bool {
    matches!(
        kind,
        "command" | "slash-command" | "app" | super::canvas_tile::KIND
    )
}

/// A keyword the composer can split off and a route segment can carry: the
/// composer cuts at the first whitespace, and `/` would leave the path segment.
pub(super) fn validate_point_name(kind: &str, name: &str) -> Result<(), ManifestError> {
    if !is_keyword_kind(kind) {
        return Ok(());
    }
    if name.len() > MAX_KEYWORD_BYTES {
        return Err(malformed(&format!(
            "extension_points[].name \"{name}\" must be at most {MAX_KEYWORD_BYTES} bytes"
        )));
    }
    if name.chars().any(|c| c.is_whitespace() || c == '/') {
        return Err(malformed(&format!(
            "extension_points[].name \"{name}\" must be a single keyword with no spaces or slashes, or it can never be typed"
        )));
    }
    Ok(())
}

/// Refuses a second point of the same name, because the first one declared
/// wins at run time and a stricter permission declared later would be ignored.
pub(super) fn reject_colliding_names(
    points: &[ManifestExtensionPoint],
) -> Result<(), ManifestError> {
    let mut seen = std::collections::HashSet::new();
    for point in points.iter().filter(|p| is_resolved_by_name(&p.kind)) {
        if !seen.insert((point.kind.as_str(), point.name.to_lowercase())) {
            return Err(malformed(&format!(
                "extension_points[].name \"{}\" is declared twice for kind {}",
                point.name, point.kind
            )));
        }
    }
    Ok(())
}
