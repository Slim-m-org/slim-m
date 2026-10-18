// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The addons repo's `index.json`: the marketplace listing, one row per module.

use serde::Deserialize;

use super::{
    MAX_LIST_ITEMS, MAX_LONG_FIELD, MAX_SHORT_FIELD, MAX_SLUG, ManifestError, SUPPORTED_SCHEMA,
    bounded, malformed, validate_slug,
};

#[derive(Deserialize)]
struct RawIndex {
    schema: i64,
    modules: Vec<RawIndexEntry>,
}

#[derive(Deserialize)]
struct RawIndexEntry {
    id: String,
    name: String,
    version: String,
    summary: String,
    /// A commit sha or tag the module's files are read from, instead of `main`.
    #[serde(default, rename = "ref")]
    reference: Option<String>,
}

/// One row of the marketplace listing.
#[derive(Debug, Clone)]
pub(in crate::http::dock) struct IndexEntry {
    pub(in crate::http::dock) id: String,
    pub(in crate::http::dock) name: String,
    pub(in crate::http::dock) version: String,
    pub(in crate::http::dock) summary: String,
    /// The immutable ref this version is read from; `None` reads `main`.
    pub(in crate::http::dock) reference: Option<String>,
}

/// A 40-hex commit sha or a plain tag name: one path segment, never `.` or `..`.
fn is_git_ref(value: &str) -> bool {
    let plain = !value.is_empty()
        && value.len() <= 64
        && value
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
        && value.chars().any(|c| c.is_ascii_alphanumeric())
        && !value.contains("..");
    plain && !value.starts_with(['.', '-'])
}

pub(in crate::http::dock) fn parse_index(bytes: &[u8]) -> Result<Vec<IndexEntry>, ManifestError> {
    let raw: RawIndex = serde_json::from_slice(bytes)
        .map_err(|e| malformed(&format!("invalid index.json: {e}")))?;
    if raw.schema != SUPPORTED_SCHEMA {
        return Err(malformed("unsupported index.json schema version"));
    }
    if raw.modules.len() > MAX_LIST_ITEMS {
        return Err(malformed("index.json lists too many modules"));
    }
    raw.modules.into_iter().map(validate_index_entry).collect()
}

fn validate_index_entry(raw: RawIndexEntry) -> Result<IndexEntry, ManifestError> {
    validate_slug(&raw.id, MAX_SLUG).map_err(|_| malformed("module id must be a safe slug"))?;
    let name = bounded(&raw.name, MAX_SHORT_FIELD, "name")?;
    let version = bounded(&raw.version, MAX_SLUG, "version")?;
    let summary = bounded(&raw.summary, MAX_LONG_FIELD, "summary")?;
    let reference = match raw.reference {
        Some(value) if is_git_ref(&value) => Some(value),
        Some(_) => return Err(malformed("index ref must be a commit sha or tag name")),
        None => None,
    };
    Ok(IndexEntry {
        id: raw.id,
        name,
        version,
        summary,
        reference,
    })
}
