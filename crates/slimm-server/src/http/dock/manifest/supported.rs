// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The artifact kind and runtime backend this host can run. Anything else is
//! refused at install rather than registered and failing at the first run;
//! widen these when a second backend ships (docs/decisions/0021).

use super::{ManifestError, malformed};

const ARTIFACT_KINDS: &[&str] = &["wasm"];
const RUNTIME_BACKENDS: &[&str] = &["wasm"];

pub(super) fn require_artifact_kind(kind: &str) -> Result<(), ManifestError> {
    require(kind, ARTIFACT_KINDS, "artifact.kind")
}

pub(super) fn require_runtime_backend(backend: &str) -> Result<(), ManifestError> {
    require(backend, RUNTIME_BACKENDS, "runtime.backend")
}

fn require(value: &str, supported: &[&str], field: &str) -> Result<(), ManifestError> {
    if supported.contains(&value) {
        return Ok(());
    }
    Err(malformed(&format!(
        "{field} {value:?} is not supported by this host (supported: {})",
        supported.join(", ")
    )))
}
