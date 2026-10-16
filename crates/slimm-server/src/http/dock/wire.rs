// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Wire DTOs for the Dock's HTTP surface, kept apart from `dock.rs`'s
//! handlers and `manifest.rs`'s parsing purely to hold the file budget - see
//! `http::link_preview`'s own split for the precedent.

use serde::Serialize;

use super::manifest::{IndexEntry, Manifest, ManifestExtensionPoint};
use crate::store::{InstalledModule, ModuleExtensionPoint, ModuleExtensionPointSpec};

#[derive(Serialize)]
pub(super) struct IndexEntryDto {
    id: String,
    name: String,
    version: String,
    summary: String,
    /// True when another source already owns this id, so it cannot be
    /// installed from the source being listed (decision 0046).
    shadowed: bool,
}

impl IndexEntryDto {
    pub(super) fn new(entry: IndexEntry, shadowed: bool) -> Self {
        Self {
            id: entry.id,
            name: entry.name,
            version: entry.version,
            summary: entry.summary,
            shadowed,
        }
    }
}

#[derive(Serialize)]
pub(super) struct ArtifactDto {
    kind: String,
    path: String,
    sha256: String,
}

#[derive(Serialize)]
pub(super) struct LimitsDto {
    memory_mb: Option<u64>,
    wall_ms: Option<u64>,
    fuel: Option<u64>,
}

#[derive(Serialize)]
pub(super) struct RuntimeDto {
    backend: String,
    limits: LimitsDto,
}

#[derive(Serialize)]
pub(super) struct PermissionDto {
    key: String,
    name: String,
    description: String,
}

#[derive(Serialize)]
pub(super) struct ExtensionPointDto {
    kind: String,
    name: String,
    description: Option<String>,
    permission: Option<String>,
    /// Omitted rather than sent as a literal `null` when absent (a `command`
    /// extension point never has one): `tests/response_contract` validates
    /// with a real JSON Schema, which has no `nullable` keyword of its own -
    /// an emitted `null` on an `Option` field the schema types as `string`
    /// fails validation outright, where an absent field on a non-`required`
    /// property does not.
    #[serde(skip_serializing_if = "Option::is_none")]
    command: Option<String>,
    /// For a `code-block-runner` only: the fenced-block language it
    /// matches, or absent for a wildcard that matches any block. Omitted
    /// rather than sent as `null`, for the same reason as `command` above.
    #[serde(skip_serializing_if = "Option::is_none")]
    language: Option<String>,
}

/// A module's full manifest, as the Dock shows an admin before install: every
/// permission it will add and every capability it asks for.
#[derive(Serialize)]
pub(super) struct ManifestDto {
    id: String,
    name: String,
    version: String,
    summary: String,
    author: Option<String>,
    artifact: ArtifactDto,
    runtime: RuntimeDto,
    permissions: Vec<PermissionDto>,
    capabilities: Vec<String>,
    extension_points: Vec<ExtensionPointDto>,
    /// Where `net.fetch` may reach; absent when the module declares none.
    #[serde(skip_serializing_if = "Option::is_none")]
    network: Option<NetworkDto>,
    /// Commands the host runs on a timer once `schedule` is approved.
    schedules: Vec<ScheduleDto>,
    /// What each version changed, newest first; empty when none is published.
    changelog: Vec<ChangelogEntryDto>,
}

#[derive(Serialize)]
pub(super) struct ChangelogEntryDto {
    version: String,
    changes: Vec<String>,
}

#[derive(Serialize)]
pub(in crate::http) struct ScheduleDto {
    command: String,
    every_minutes: u32,
}

#[derive(Serialize)]
pub(super) struct NetworkDto {
    hosts: Vec<String>,
    /// Whether the module asks to reach local network addresses.
    local: bool,
}

impl From<Manifest> for ManifestDto {
    fn from(m: Manifest) -> Self {
        Self {
            id: m.id,
            name: m.name,
            version: m.version,
            summary: m.summary,
            author: m.author,
            artifact: ArtifactDto {
                kind: m.artifact.kind,
                path: m.artifact.path,
                sha256: m.artifact.sha256,
            },
            runtime: RuntimeDto {
                backend: m.runtime.backend,
                limits: LimitsDto {
                    memory_mb: m.runtime.limits.memory_mb,
                    wall_ms: m.runtime.limits.wall_ms,
                    fuel: m.runtime.limits.fuel,
                },
            },
            permissions: m
                .permissions
                .into_iter()
                .map(|p| PermissionDto {
                    key: p.key,
                    name: p.name,
                    description: p.description,
                })
                .collect(),
            capabilities: m.capabilities,
            extension_points: m.extension_points.into_iter().map(Into::into).collect(),
            network: (!m.network.hosts.is_empty()).then_some(NetworkDto {
                hosts: m.network.hosts,
                local: m.network.local,
            }),
            schedules: m
                .schedules
                .into_iter()
                .map(|s| ScheduleDto {
                    command: s.command,
                    every_minutes: s.every_minutes,
                })
                .collect(),
            changelog: m
                .changelog
                .into_iter()
                .map(|e| ChangelogEntryDto {
                    version: e.version,
                    changes: e.changes,
                })
                .collect(),
        }
    }
}

/// One installed module, as `GET /space/dock/installed` and every lifecycle
/// verb answer with. `extension_points` is surfaced here (rather than only
/// in the pre-install `ManifestDto`) so a client can discover which commands
/// an already-installed module offers, and which permission each needs,
/// without re-browsing the Dock.
#[derive(Serialize)]
pub(in crate::http) struct InstalledModuleDto {
    id: String,
    name: String,
    version: String,
    artifact_sha256: String,
    approved_capabilities: Vec<String>,
    /// The host capabilities an admin approved the module to use at install;
    /// empty for a module installed before that approval existed.
    approved_host_capabilities: Vec<String>,
    extension_points: Vec<ExtensionPointDto>,
    enabled: bool,
    installed_at: i64,
    /// The community source's `owner/repo`; absent for the official source.
    #[serde(skip_serializing_if = "Option::is_none")]
    source_repo: Option<String>,
    /// The hosts approved with `net.fetch`; empty without it.
    network_hosts: Vec<String>,
    /// Whether the admin gave the second approval for local addresses.
    local_network_approved: bool,
    schedules: Vec<ScheduleDto>,
    /// The module's own principal, which its scheduled runs post as.
    #[serde(skip_serializing_if = "Option::is_none")]
    bot_user_id: Option<String>,
    /// Where its scheduled runs post; absent until an admin chooses.
    #[serde(skip_serializing_if = "Option::is_none")]
    schedule_channel_id: Option<String>,
}

impl From<InstalledModule> for InstalledModuleDto {
    fn from(m: InstalledModule) -> Self {
        Self {
            id: m.id,
            name: m.name,
            version: m.version,
            artifact_sha256: m.artifact_sha256,
            approved_capabilities: m.approved_capabilities,
            approved_host_capabilities: m.approved_host_capabilities,
            extension_points: m.extension_points.into_iter().map(Into::into).collect(),
            enabled: m.enabled,
            installed_at: m.installed_at,
            source_repo: m.source_repo,
            network_hosts: m.network_hosts,
            local_network_approved: m.local_network_approved,
            schedules: m
                .schedules
                .into_iter()
                .map(|s| ScheduleDto {
                    command: s.command,
                    every_minutes: s.every_minutes,
                })
                .collect(),
            bot_user_id: m.bot_user_id.map(|id| id.to_string()),
            schedule_channel_id: m.schedule_channel_id.map(|id| id.to_string()),
        }
    }
}

impl From<ManifestExtensionPoint> for ExtensionPointDto {
    fn from(e: ManifestExtensionPoint) -> Self {
        Self {
            kind: e.kind,
            name: e.name,
            description: e.description,
            permission: e.permission,
            command: e.command,
            language: e.language,
        }
    }
}

impl From<ModuleExtensionPoint> for ExtensionPointDto {
    fn from(e: ModuleExtensionPoint) -> Self {
        Self {
            kind: e.kind,
            name: e.name,
            description: e.description,
            permission: e.permission,
            command: e.command,
            language: e.language,
        }
    }
}

impl<'a> From<&'a ManifestExtensionPoint> for ModuleExtensionPointSpec<'a> {
    fn from(e: &'a ManifestExtensionPoint) -> Self {
        Self {
            kind: &e.kind,
            name: &e.name,
            description: e.description.as_deref(),
            permission: e.permission.as_deref(),
            command: e.command.as_deref(),
            language: e.language.as_deref(),
        }
    }
}
