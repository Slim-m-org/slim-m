// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The install step shared by every way a module reaches the Dock: a manifest
//! the admin reviewed and an artifact the manifest's sha256 vouches for. Where
//! the two came from (a registry or a package file) changes the provenance
//! recorded, never the checks.

use serde::Deserialize;

use super::capabilities::{
    approvable_host_capabilities, carried_host_capabilities, held_hooks, local_network_approval,
};
use super::dock_fetch::fetch_artifact;
use super::keywords::ensure_slash_keywords_free;
use super::manifest::{self, Manifest};
use super::sources::Origin;
use super::wire::InstalledModuleDto;
use super::{Enabled, module_data};
use crate::http::AppState;
use crate::http::error::ApiError;
use crate::http::{module_events, module_host};
use crate::store::{
    DockProvenance, InstallModuleRequest, ModuleExtensionPointSpec, ModulePermissionSpec,
    ModuleRuntimeLimits, ModuleSchedule,
};

/// Where the artifact bytes come from, already checked against the manifest's sha256 or about to be.
pub(super) enum ArtifactSource<'a> {
    /// A registry the install fetches from.
    Fetch {
        dock: &'a Enabled,
        origin: &'a Origin,
    },
    /// Bytes the caller already holds and has verified.
    Bytes(Vec<u8>),
}

impl ArtifactSource<'_> {
    async fn bytes(self, manifest: &Manifest) -> Result<Vec<u8>, ApiError> {
        match self {
            Self::Fetch { dock, origin } => fetch_artifact(dock, origin, manifest).await,
            Self::Bytes(bytes) => Ok(bytes),
        }
    }
}

#[derive(Deserialize)]
pub(super) struct InstallRequest {
    /// The version the admin reviewed in the Dock before installing. Checked
    /// against the freshly re-fetched manifest's own `version` so a race
    /// with an upstream release cannot install something nobody reviewed.
    pub(super) version: String,
    /// The host capabilities the admin approved after seeing them listed
    /// (decision 0023). Each must be one the manifest declared and the host
    /// implements. Omitted keeps what was approved before, minus anything the
    /// new manifest no longer declares, and never adds one; an empty list
    /// withdraws every approval.
    #[serde(default)]
    pub(super) approved_host_capabilities: Option<Vec<String>>,
    /// The second, separate approval for `net.fetch` to reach local network
    /// addresses. Omitted keeps an earlier approval for the same hosts.
    #[serde(default)]
    pub(super) approve_local_network: Option<bool>,
    /// The `review_digest` of the manifest the admin was shown. Refused when
    /// the manifest has changed since, so consent is for what was reviewed.
    #[serde(default)]
    pub(super) reviewed_digest: Option<String>,
}

/// Checks the admin's review and approvals against `manifest`, then stores the
/// module. `repo` is the provenance recorded: `None` is the official source.
pub(super) async fn install_manifest(
    state: &AppState,
    manifest: &Manifest,
    artifact: ArtifactSource<'_>,
    req: &InstallRequest,
    repo: Option<&str>,
) -> Result<InstalledModuleDto, ApiError> {
    let id = manifest.id.as_str();
    if manifest.version != req.version {
        return Err(ApiError::Conflict(
            "the module's current version no longer matches the one requested; reopen it in the Dock",
        ));
    }
    if req
        .reviewed_digest
        .as_deref()
        .is_some_and(|reviewed| reviewed != manifest.review_digest())
    {
        return Err(ApiError::Conflict(
            "the module changed since you reviewed it; reopen it in the Dock",
        ));
    }
    let approved_host = match &req.approved_host_capabilities {
        Some(requested) => approvable_host_capabilities(manifest, requested)?,
        None => carried_host_capabilities(state, manifest).await?,
    };
    let local_network =
        local_network_approval(state, manifest, &approved_host, req.approve_local_network).await?;
    let network_hosts: &[String] = if approved_host.iter().any(|c| c == manifest::NET_FETCH) {
        &manifest.network.hosts
    } else {
        &[]
    };
    if state
        .store
        .installed_module(id)
        .await?
        .is_some_and(|m| m.enabled)
    {
        let keywords = manifest
            .extension_points
            .iter()
            .filter(|e| e.kind == "slash-command")
            .map(|e| e.name.as_str());
        ensure_slash_keywords_free(state, id, keywords).await?;
    }
    module_data::check(state, manifest, &approved_host).await?;
    let artifact = artifact.bytes(manifest).await?;

    let permissions: Vec<ModulePermissionSpec> = manifest
        .permissions
        .iter()
        .map(|p| ModulePermissionSpec {
            key: &p.key,
            name: &p.name,
            description: &p.description,
        })
        .collect();
    let extension_points: Vec<ModuleExtensionPointSpec> =
        manifest.extension_points.iter().map(Into::into).collect();
    let schedules: Vec<ModuleSchedule> = manifest
        .schedules
        .iter()
        .map(|s| ModuleSchedule {
            command: s.command.clone(),
            every_minutes: s.every_minutes,
        })
        .collect();
    let runtime_limits = ModuleRuntimeLimits {
        memory_mb: manifest.runtime.limits.memory_mb,
        wall_ms: manifest.runtime.limits.wall_ms,
        fuel: manifest.runtime.limits.fuel,
    };
    let installed = state
        .store
        .install_module_from_dock(
            InstallModuleRequest {
                id: &manifest.id,
                name: &manifest.name,
                version: &manifest.version,
                artifact_sha256: &manifest.artifact.sha256,
                approved_capabilities: &manifest.capabilities,
                runtime_limits: &runtime_limits,
                permissions: &permissions,
                extension_points: &extension_points,
            },
            &artifact,
            &DockProvenance {
                host_capabilities: &approved_host,
                source_repo: repo,
                manifest_json: Some(&manifest.raw_json),
                network_hosts,
                local_network_approved: local_network,
                schedules: &schedules,
                platform: &manifest.platform,
            },
        )
        .await?;
    module_data::apply(state, manifest, &approved_host).await?;
    state.dock.slot_cache().invalidate_module(&installed.id);
    let installed = if module_host::schedule_approved(&installed)
        || module_events::events_approved(&installed)
        || module_host::logs_approved(&installed)
    {
        state
            .store
            .ensure_module_bot(&installed.id, &installed.name)
            .await?;
        state
            .store
            .installed_module(&installed.id)
            .await?
            .ok_or(ApiError::Internal)?
    } else {
        installed
    };
    let hooks = held_hooks(state, &installed.id).await?;
    Ok(InstalledModuleDto::from(installed).with_hooks(&hooks))
}
