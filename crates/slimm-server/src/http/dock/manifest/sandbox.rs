// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The artifact and runtime a WASM module declares, and the placeholders a connector reads as.

use super::{
    MAX_LONG_FIELD, MAX_SLUG, ManifestArtifact, ManifestError, ManifestLimits, ManifestRuntime,
    RawArtifact, RawRuntime, artifact_path, bounded, connector, is_sha256_hex, malformed,
    supported,
};
use crate::module_runtime::{MAX_FUEL, MAX_MEMORY_MB, MAX_WALL_MS};

/// A WASM module must declare both; a connector declares neither (checked in `connector`).
pub(super) fn validate(
    is_connector: bool,
    artifact: Option<RawArtifact>,
    runtime: Option<RawRuntime>,
) -> Result<(ManifestArtifact, ManifestRuntime), ManifestError> {
    if is_connector {
        return Ok((connector::no_artifact(), connector::no_runtime()));
    }
    match (artifact, runtime) {
        (Some(artifact), Some(runtime)) => {
            Ok((validate_artifact(artifact)?, validate_runtime(runtime)?))
        }
        _ => Err(malformed("a module must declare artifact and runtime")),
    }
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
