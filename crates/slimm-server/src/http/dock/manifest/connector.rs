// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `"provider": "connector"` (decision 0090, add-on API 7): a module whose
//! logic is an external program holding a bot token, so it has no artifact
//! and no runtime, and asks for core permissions instead of host capabilities.
//!
//! What a WASM module declares about its own sandbox (capabilities, network,
//! schedules, events, hooks, data, call audio, commands and slots) has no
//! meaning for a program the host does not run, so a connector may declare
//! none of it. Settings are the one shared section.

use serde::Deserialize;

use super::{ManifestArtifact, ManifestError, ManifestLimits, ManifestRuntime, RawManifest};
use super::{malformed, validate_slug};
use crate::permissions::Permissions;
use crate::permissions::names::by_name;

/// The add-on API level that added connectors.
pub(in crate::http) const CONNECTOR_API: u32 = 7;
/// The `provider` value, and the artifact kind and backend a connector reads as.
pub(in crate::http) const CONNECTOR: &str = "connector";
const WASM: &str = "wasm";

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct RawConnector {
    /// Core permission names, such as `send_messages`.
    permissions: Vec<String>,
}

/// What a connector asks the admin to approve for its token.
#[derive(Debug, Clone)]
pub(in crate::http) struct ManifestConnector {
    pub(in crate::http) permissions: Permissions,
}

/// `Some` for a connector manifest, after refusing anything a connector cannot declare.
pub(super) fn validate(raw: &mut RawManifest) -> Result<Option<ManifestConnector>, ManifestError> {
    let provider = raw.provider.as_deref().unwrap_or(WASM);
    match provider {
        WASM if raw.connector.is_some() => Err(malformed(
            "connector is only allowed with \"provider\": \"connector\"",
        )),
        WASM => Ok(None),
        CONNECTOR => {
            refuse_wasm_sections(raw)?;
            let connector = raw
                .connector
                .take()
                .ok_or_else(|| malformed("a connector must declare connector.permissions"))?;
            Ok(Some(ManifestConnector {
                permissions: permissions(&connector.permissions)?,
            }))
        }
        other => Err(malformed(&format!(
            "provider {other:?} is not supported by this host (supported: wasm, connector)"
        ))),
    }
}

/// A connector needs `"addon_api": 7`, so an older host refuses it rather than installing a WASM module with no artifact.
pub(super) fn require_level(
    connector: Option<&ManifestConnector>,
    addon_api: u32,
) -> Result<(), ManifestError> {
    match connector {
        Some(_) if addon_api < CONNECTOR_API => Err(malformed(&format!(
            "a connector needs \"addon_api\": {CONNECTOR_API} or higher"
        ))),
        _ => Ok(()),
    }
}

fn refuse_wasm_sections(raw: &RawManifest) -> Result<(), ManifestError> {
    let declared = [
        ("artifact", raw.artifact.is_some()),
        ("runtime", raw.runtime.is_some()),
        ("permissions", !raw.permissions.is_empty()),
        ("capabilities", !raw.capabilities.is_empty()),
        ("extension_points", !raw.extension_points.is_empty()),
        ("network", raw.network.is_some()),
        ("schedules", !raw.schedules.is_empty()),
        ("subscriptions", !raw.subscriptions.is_empty()),
        ("slots", !raw.slots.is_empty()),
        ("interceptors", !raw.interceptors.is_empty()),
        ("permission_hooks", !raw.permission_hooks.is_empty()),
        ("data", raw.data.is_some()),
        ("call_audio", raw.call_audio.is_some()),
    ];
    match declared.iter().find(|(_, present)| *present) {
        Some((field, _)) => Err(malformed(&format!("a connector may not declare {field}"))),
        None => Ok(()),
    }
}

fn permissions(names: &[String]) -> Result<Permissions, ManifestError> {
    if names.len() > super::MAX_LIST_ITEMS {
        return Err(malformed("connector.permissions is too long"));
    }
    let mut asked = Permissions::NONE;
    for name in names {
        validate_slug(&name.replace('_', "-"), super::MAX_SLUG)
            .map_err(|_| malformed("connector.permissions names must be lowercase"))?;
        let bit = by_name(name).ok_or_else(|| {
            malformed(&format!(
                "connector.permissions names an unknown permission {name:?}"
            ))
        })?;
        if asked.contains(bit) {
            return Err(malformed("connector.permissions repeats a permission"));
        }
        asked = asked.union(bit);
    }
    Ok(asked)
}

/// The artifact a connector reads as: none, said plainly so an older client still parses it.
pub(super) fn no_artifact() -> ManifestArtifact {
    ManifestArtifact {
        kind: CONNECTOR.to_owned(),
        path: String::new(),
        sha256: String::new(),
    }
}

/// The runtime a connector reads as: the host runs nothing.
pub(super) fn no_runtime() -> ManifestRuntime {
    ManifestRuntime {
        backend: CONNECTOR.to_owned(),
        limits: ManifestLimits {
            memory_mb: None,
            wall_ms: None,
            fuel: None,
        },
    }
}

#[cfg(test)]
mod tests;
