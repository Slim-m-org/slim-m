// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Parsing and strict validation of the addons repo's `index.json` and a
//! module's `manifest.json`, per docs/decisions/0021-modules-and-the-dock.md.
//! Pure: no I/O, no database, so every shape here is unit-testable against a
//! literal string.
//!
//! Nothing here trusts the wire shape beyond what [`serde`] itself checks;
//! [`validate_manifest`] and [`validate_index`] then reject anything
//! structurally well-formed JSON but not a manifest this server is willing
//! to install - an unsafe id or permission key, an empty or oversized field,
//! a `sha256` that is not 64 hex characters.

use serde::{Deserialize, Serialize};

use super::super::hidden_chars::is_hidden_char;
use crate::module_runtime::{MAX_FUEL, MAX_MEMORY_MB, MAX_WALL_MS};

/// The one schema version this server understands. A registry that bumps it
/// is a breaking change to the wire contract, not something to guess at.
const SUPPORTED_SCHEMA: i64 = 1;

const MAX_SHORT_FIELD: usize = 200;
const MAX_LONG_FIELD: usize = 2000;
const MAX_SLUG: usize = 64;
const MAX_LIST_ITEMS: usize = 64;

/// Why a fetched index or manifest was refused.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum ManifestError {
    /// Not valid JSON, or missing/mistyped a required field.
    Malformed(String),
}

fn malformed(reason: &str) -> ManifestError {
    ManifestError::Malformed(reason.to_owned())
}

// --- index.json ---

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
}

/// One row of the marketplace listing.
#[derive(Debug, Clone, Serialize)]
pub(super) struct IndexEntry {
    pub(super) id: String,
    pub(super) name: String,
    pub(super) version: String,
    pub(super) summary: String,
}

pub(super) fn parse_index(bytes: &[u8]) -> Result<Vec<IndexEntry>, ManifestError> {
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
    Ok(IndexEntry {
        id: raw.id,
        name,
        version,
        summary,
    })
}

// --- manifest.json ---

#[derive(Deserialize)]
struct RawManifest {
    schema: i64,
    id: String,
    name: String,
    version: String,
    summary: String,
    #[serde(default)]
    author: Option<String>,
    artifact: RawArtifact,
    runtime: RawRuntime,
    #[serde(default)]
    permissions: Vec<RawPermission>,
    #[serde(default)]
    capabilities: Vec<String>,
    #[serde(default)]
    extension_points: Vec<RawExtensionPoint>,
}

#[derive(Deserialize)]
struct RawArtifact {
    kind: String,
    path: String,
    sha256: String,
}

#[derive(Deserialize)]
struct RawRuntime {
    backend: String,
    #[serde(default)]
    limits: RawLimits,
}

#[derive(Deserialize, Default)]
struct RawLimits {
    #[serde(default)]
    memory_mb: Option<u64>,
    #[serde(default)]
    wall_ms: Option<u64>,
    #[serde(default)]
    fuel: Option<u64>,
}

#[derive(Deserialize)]
struct RawPermission {
    key: String,
    name: String,
    description: String,
}

#[derive(Deserialize)]
struct RawExtensionPoint {
    kind: String,
    name: String,
    #[serde(default)]
    description: Option<String>,
    /// The declared permission key (see `permissions` above) a caller must
    /// hold to reach this extension point. Required for `kind: "command"`,
    /// `"code-block-runner"`, `"slash-command"` and `"app"`, per the module
    /// runtime's own permission gate (`http::module_commands`); optional for
    /// any future kind that adds no permission of its own.
    #[serde(default)]
    permission: Option<String>,
    /// For the runner-like kinds (`code-block-runner`, `slash-command`,
    /// `app`): the `command` extension point's own `name` this one invokes -
    /// the module must declare both, so a discovery call can hand back a
    /// `(module_id, command)` pair that
    /// `POST /modules/{moduleId}/commands/{command}` is guaranteed to accept.
    #[serde(default)]
    command: Option<String>,
    /// For `kind: "code-block-runner"` only: the fenced-block language this
    /// runner matches (a short slug such as `javascript`). Absent means a
    /// wildcard - the client offers it for any block - so a deployment with
    /// a single, older runner keeps working unmatched. Never meaningful for
    /// any other kind.
    #[serde(default)]
    language: Option<String>,
}

/// A module's declared permission, validated: `key` is a safe slug, `name`
/// and `description` are non-empty and bounded.
#[derive(Debug, Clone, Serialize)]
pub(super) struct ManifestPermission {
    pub(super) key: String,
    pub(super) name: String,
    pub(super) description: String,
}

#[derive(Debug, Clone, Serialize)]
pub(super) struct ManifestArtifact {
    pub(super) kind: String,
    pub(super) path: String,
    pub(super) sha256: String,
}

#[derive(Debug, Clone, Serialize)]
pub(super) struct ManifestLimits {
    pub(super) memory_mb: Option<u64>,
    pub(super) wall_ms: Option<u64>,
    pub(super) fuel: Option<u64>,
}

#[derive(Debug, Clone, Serialize)]
pub(super) struct ManifestRuntime {
    pub(super) backend: String,
    pub(super) limits: ManifestLimits,
}

#[derive(Debug, Clone, Serialize)]
pub(super) struct ManifestExtensionPoint {
    pub(super) kind: String,
    pub(super) name: String,
    pub(super) description: Option<String>,
    pub(super) permission: Option<String>,
    pub(super) command: Option<String>,
    pub(super) language: Option<String>,
}

/// A fully parsed and validated module manifest.
#[derive(Debug, Clone, Serialize)]
pub(super) struct Manifest {
    pub(super) id: String,
    pub(super) name: String,
    pub(super) version: String,
    pub(super) summary: String,
    pub(super) author: Option<String>,
    pub(super) artifact: ManifestArtifact,
    pub(super) runtime: ManifestRuntime,
    pub(super) permissions: Vec<ManifestPermission>,
    pub(super) capabilities: Vec<String>,
    pub(super) extension_points: Vec<ManifestExtensionPoint>,
}

pub(super) fn parse_manifest(bytes: &[u8]) -> Result<Manifest, ManifestError> {
    let raw: RawManifest = serde_json::from_slice(bytes)
        .map_err(|e| malformed(&format!("invalid manifest.json: {e}")))?;
    validate_manifest(raw)
}

fn validate_manifest(raw: RawManifest) -> Result<Manifest, ManifestError> {
    if raw.schema != SUPPORTED_SCHEMA {
        return Err(malformed("unsupported manifest.json schema version"));
    }
    validate_slug(&raw.id, MAX_SLUG).map_err(|_| malformed("module id must be a safe slug"))?;
    let name = bounded(&raw.name, MAX_SHORT_FIELD, "name")?;
    let version = bounded(&raw.version, MAX_SLUG, "version")?;
    let summary = bounded(&raw.summary, MAX_LONG_FIELD, "summary")?;
    let author = raw
        .author
        .map(|a| bounded(&a, MAX_SHORT_FIELD, "author"))
        .transpose()?;

    let artifact = validate_artifact(raw.artifact)?;
    let runtime = validate_runtime(raw.runtime)?;

    if raw.permissions.len() > MAX_LIST_ITEMS {
        return Err(malformed("manifest declares too many permissions"));
    }
    let permissions = raw
        .permissions
        .into_iter()
        .map(validate_permission)
        .collect::<Result<Vec<_>, _>>()?;
    let mut seen_keys = std::collections::HashSet::new();
    for perm in &permissions {
        if !seen_keys.insert(perm.key.clone()) {
            return Err(malformed("duplicate permission key in manifest"));
        }
    }

    if raw.capabilities.len() > MAX_LIST_ITEMS {
        return Err(malformed("manifest declares too many capabilities"));
    }
    let capabilities = raw
        .capabilities
        .iter()
        .map(|c| bounded(c, MAX_SHORT_FIELD, "capability"))
        .collect::<Result<Vec<_>, _>>()?;

    if raw.extension_points.len() > MAX_LIST_ITEMS {
        return Err(malformed("manifest declares too many extension points"));
    }
    // Collected before validation consumes the list, so a `code-block-runner` can be checked against its sibling `command` names, the same way `seen_keys` checks against `permissions`.
    let command_names: std::collections::HashSet<String> = raw
        .extension_points
        .iter()
        .filter(|ep| ep.kind == "command")
        .map(|ep| ep.name.trim().to_owned())
        .collect();
    let extension_points = raw
        .extension_points
        .into_iter()
        .map(|ep| validate_extension_point(ep, &seen_keys, &command_names))
        .collect::<Result<Vec<_>, _>>()?;
    names::reject_colliding_names(&extension_points)?;

    Ok(Manifest {
        id: raw.id,
        name,
        version,
        summary,
        author,
        artifact,
        runtime,
        permissions,
        capabilities,
        extension_points,
    })
}

fn validate_artifact(raw: RawArtifact) -> Result<ManifestArtifact, ManifestError> {
    let kind = bounded(&raw.kind, MAX_SLUG, "artifact.kind")?;
    supported::require_artifact_kind(&kind)?;
    if raw.path.is_empty()
        || raw.path.len() > MAX_LONG_FIELD
        || !artifact_path::is_plain_relative_path(&raw.path)
    {
        return Err(malformed("artifact.path is not a safe relative path"));
    }
    if !is_sha256_hex(&raw.sha256) {
        return Err(malformed("artifact.sha256 must be 64 hex characters"));
    }
    Ok(ManifestArtifact {
        kind,
        path: raw.path,
        sha256: raw.sha256,
    })
}

fn validate_runtime(raw: RawRuntime) -> Result<ManifestRuntime, ManifestError> {
    let backend = bounded(&raw.backend, MAX_SLUG, "runtime.backend")?;
    supported::require_runtime_backend(&backend)?;
    for (value, field, max) in [
        (raw.limits.memory_mb, "memory_mb", MAX_MEMORY_MB),
        (raw.limits.wall_ms, "wall_ms", MAX_WALL_MS),
        (raw.limits.fuel, "fuel", MAX_FUEL),
    ] {
        if value == Some(0) {
            return Err(malformed(&format!(
                "runtime.limits.{field} must be positive"
            )));
        }
        if value.is_some_and(|v| v > max) {
            return Err(malformed(&format!(
                "runtime.limits.{field} may not exceed {max}"
            )));
        }
    }
    Ok(ManifestRuntime {
        backend,
        limits: ManifestLimits {
            memory_mb: raw.limits.memory_mb,
            wall_ms: raw.limits.wall_ms,
            fuel: raw.limits.fuel,
        },
    })
}

fn validate_permission(raw: RawPermission) -> Result<ManifestPermission, ManifestError> {
    validate_slug(&raw.key, MAX_SLUG)
        .map_err(|_| malformed("permission.key must be a safe slug"))?;
    let name = bounded(&raw.name, MAX_SHORT_FIELD, "permission.name")?;
    let description = bounded(&raw.description, MAX_LONG_FIELD, "permission.description")?;
    Ok(ManifestPermission {
        key: raw.key,
        name,
        description,
    })
}

/// `permission_keys` is the manifest's own declared permission keys
/// (`permissions[].key`, already validated), checked against here so a
/// command cannot name a permission the manifest never declares - the
/// module runtime otherwise has no way to tell an admin's `MANAGE_ROLES`
/// grant surface apart from a typo. `command_names` is likewise the
/// manifest's own `command` extension point names, checked against a
/// `code-block-runner`'s own `command` field for the same reason.
/// The extension point must declare a `permission` naming one of this
/// manifest's own permission keys; [kind] names it in the error.
fn require_declared_permission(
    kind: &str,
    permission: &Option<String>,
    permission_keys: &std::collections::HashSet<String>,
) -> Result<(), ManifestError> {
    match permission {
        Some(key) if permission_keys.contains(key) => Ok(()),
        Some(_) => Err(malformed(&format!(
            "a {kind} extension point's permission must name a permission this manifest declares"
        ))),
        None => Err(malformed(&format!(
            "a {kind} extension point must declare which permission it requires"
        ))),
    }
}

/// The extension point must declare a `command` naming one of this manifest's
/// own `command` extension points; [kind] names it in the error.
fn require_declared_command(
    kind: &str,
    command: &Option<String>,
    command_names: &std::collections::HashSet<String>,
) -> Result<(), ManifestError> {
    match command {
        Some(cmd) if command_names.contains(cmd) => Ok(()),
        Some(_) => Err(malformed(&format!(
            "a {kind} extension point's command must name a command this manifest declares"
        ))),
        None => Err(malformed(&format!(
            "a {kind} extension point must declare which command it runs"
        ))),
    }
}

fn validate_extension_point(
    raw: RawExtensionPoint,
    permission_keys: &std::collections::HashSet<String>,
    command_names: &std::collections::HashSet<String>,
) -> Result<ManifestExtensionPoint, ManifestError> {
    let kind = bounded(&raw.kind, MAX_SLUG, "extension_points[].kind")?;
    let name = bounded(&raw.name, MAX_SHORT_FIELD, "extension_points[].name")?;
    names::validate_point_name(&kind, &name)?;
    let description = raw
        .description
        .map(|d| bounded(&d, MAX_LONG_FIELD, "extension_points[].description"))
        .transpose()?;
    let permission = raw
        .permission
        .map(|p| bounded(&p, MAX_SLUG, "extension_points[].permission"))
        .transpose()?;
    let command = raw
        .command
        .map(|c| bounded(&c, MAX_SHORT_FIELD, "extension_points[].command"))
        .transpose()?;
    let language = raw
        .language
        .map(|l| {
            validate_slug(&l, MAX_SLUG)
                .map(|()| l)
                .map_err(|_| malformed("extension_points[].language must be a safe slug"))
        })
        .transpose()?;
    // Every known kind gates on a declared permission; the runner-like kinds (all but bare `command`) also name a command they invoke.
    match kind.as_str() {
        "command" => require_declared_permission(&kind, &permission, permission_keys)?,
        "code-block-runner" | "slash-command" | "app" => {
            require_declared_permission(&kind, &permission, permission_keys)?;
            require_declared_command(&kind, &command, command_names)?;
        }
        _ => {}
    }
    Ok(ManifestExtensionPoint {
        kind,
        name,
        description,
        permission,
        command,
        language,
    })
}

/// A safe slug: lowercase ascii letters, digits, and hyphens only, non-empty
/// and no longer than `max_len`. Used for a module id and a permission key
/// alike, per this feature's own requirement that both are safe to embed in
/// a URL path segment and a namespaced permission string (`module_id:key`).
pub(super) fn validate_slug(value: &str, max_len: usize) -> Result<(), ()> {
    if value.is_empty() || value.len() > max_len {
        return Err(());
    }
    if value
        .bytes()
        .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
    {
        Ok(())
    } else {
        Err(())
    }
}

fn bounded(value: &str, max_len: usize, field: &str) -> Result<String, ManifestError> {
    let trimmed = value.trim();
    if trimmed.is_empty() || trimmed.chars().count() > max_len {
        return Err(malformed(&format!(
            "{field} must be 1 to {max_len} characters"
        )));
    }
    if trimmed.chars().any(is_hidden_char) {
        return Err(malformed(&format!(
            "{field} must not contain control or hidden text-direction characters"
        )));
    }
    Ok(trimmed.to_owned())
}

fn is_sha256_hex(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|b| b.is_ascii_hexdigit())
}

mod artifact_path;
mod names;
mod supported;

#[cfg(test)]
mod tests;

#[cfg(test)]
mod validation_tests;
