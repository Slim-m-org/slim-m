// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Installing a connector from the Dock and re-keying it (decision 0090). The
//! admin approves the core permissions it asks for; the host creates its
//! principal and a token that can never reach past that approval, and shows
//! the token once.

use axum::extract::{Path, State};
use axum::http::request::Parts;
use serde::Serialize;

use super::dock_install::InstallRequest;
use super::manifest::Manifest;
use super::validate_module_id;
use super::wire::InstalledModuleDto;
use crate::http::AppState;
use crate::http::error::ApiError;
use crate::http::extract::{Authed, Json, enforce, require_human, require_manage_server};
use crate::ids::{SessionId, UserId};
use crate::permissions::Permissions;
use crate::ratelimit::Class;
use crate::store::{
    ConnectorInstall, DockProvenance, InstallModuleRequest, InstalledModule,
    ModuleExtensionPointSpec, ModulePermissionSpec, ModuleRuntimeLimits,
};

/// Told to an app too old to show what a connector asks for, so it cannot install one blind.
const UPDATE_THE_APP: &str =
    "this add-on is a connector, which this app cannot install; update the app";

/// The connector half of `install_manifest`, once the version and review digest are checked.
pub(super) async fn install(
    state: &AppState,
    manifest: &Manifest,
    req: &InstallRequest,
    repo: Option<&str>,
    actor: UserId,
) -> Result<InstalledModuleDto, ApiError> {
    let Some(connector) = &manifest.connector else {
        return Err(ApiError::Internal);
    };
    require_human(state, actor).await?;
    let approved = req
        .approved_connector_permissions
        .ok_or(ApiError::BadRequest(UPDATE_THE_APP))?;
    let approved = crate::http::roles::grantable(
        state.store.granted_base_permissions(actor).await?,
        approved,
    )?;
    if !connector.permissions.contains(approved) {
        return Err(ApiError::BadRequest(
            "a connector can only be approved permissions it asks for",
        ));
    }
    let host_run = match &connector.host_run {
        Some(asked) => Some(super::dock_host_run::approve(
            state,
            asked,
            req.approved_host_run.as_ref(),
        )?),
        None => None,
    };
    let installed_before = state.store.installed_module(&manifest.id).await?;
    if installed_before.as_ref().is_some_and(|m| !m.is_connector()) {
        return Err(ApiError::Conflict(
            "a module with this id is installed; uninstall it before installing the connector",
        ));
    }
    if installed_before.is_some_and(|m| m.enabled) {
        let keywords = manifest
            .extension_points
            .iter()
            .filter(|e| e.kind == "slash-command")
            .map(|e| e.name.as_str());
        super::keywords::ensure_slash_keywords_free(state, &manifest.id, keywords).await?;
    }
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
    let provenance = DockProvenance {
        host_capabilities: &[],
        source_repo: repo,
        manifest_json: Some(&manifest.raw_json),
        network_hosts: &[],
        local_network_approved: false,
        schedules: &[],
        platform: &manifest.platform,
    };
    let installed = state
        .store
        .install_connector(ConnectorInstall {
            module: InstallModuleRequest {
                id: &manifest.id,
                name: &manifest.name,
                version: &manifest.version,
                artifact_sha256: &manifest.artifact.sha256,
                approved_capabilities: &[],
                runtime_limits: &ModuleRuntimeLimits::default(),
                permissions: &permissions,
                extension_points: &extension_points,
            },
            provenance: &provenance,
            approved,
            installed_by: actor,
        })
        .await?;
    state.dock.slot_cache().invalidate_module(&manifest.id);
    if let Some((runner, spec)) = host_run {
        super::dock_host_run::after_store_install(state, &runner, &manifest.id, &spec).await?;
        return Ok(InstalledModuleDto::from(installed.module));
    }
    let switched = super::dock_host_run::no_longer_host_run(state, &manifest.id, actor).await?;
    let token = switched.or(installed.token);
    Ok(InstalledModuleDto::from(installed.module).with_connector_token(token))
}

/// Refuses a WASM install over a connector of the same id, which would leave its principal uncapped.
pub(super) fn refuse_replacing_connector(
    installed: Option<&InstalledModule>,
) -> Result<(), ApiError> {
    match installed {
        Some(m) if m.is_connector() => Err(ApiError::Conflict(
            "a connector with this id is installed; uninstall it before installing the module",
        )),
        _ => Ok(()),
    }
}

#[derive(Serialize)]
pub(super) struct ConnectorTokenDto {
    token: String,
}

/// Replaces a connector's token for an admin who lost it; the new one is shown once.
pub(super) async fn reissue_token(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    Path(id): Path<String>,
) -> Result<Json<ConnectorTokenDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    require_manage_server(&state, ctx.user_id).await?;
    require_human(&state, ctx.user_id).await?;
    validate_module_id(&id)?;
    if state.store.host_run(&id).await?.is_some() {
        return Err(ApiError::Conflict(
            "the host holds this connector's token, which never leaves it",
        ));
    }
    let (token, revoked) = state
        .store
        .reissue_connector_token(&id, ctx.user_id)
        .await?
        .ok_or(ApiError::NotFound("no connector is installed with that id"))?;
    close_sessions(&state, revoked);
    Ok(Json(ConnectorTokenDto { token }))
}

/// Closes the sockets a revoked token held.
pub(super) fn close_sessions(state: &AppState, revoked: Vec<SessionId>) {
    crate::http::session_revocation::sessions_revoked_by_id(state, revoked);
}

/// The core permissions a connector manifest asks for, as the Dock shows them before install.
#[derive(Serialize, Default)]
pub(in crate::http) struct ConnectorAskDto {
    #[serde(skip_serializing_if = "Option::is_none")]
    provider: Option<&'static str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    connector: Option<AskedDto>,
}

#[derive(Serialize)]
struct AskedDto {
    permissions: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    host_run: Option<super::dock_host_run::HostRunAskDto>,
}

impl ConnectorAskDto {
    pub(super) fn of(manifest: &Manifest) -> Self {
        match &manifest.connector {
            Some(c) => Self {
                provider: Some(super::manifest::connector::CONNECTOR),
                connector: Some(AskedDto {
                    permissions: c.permissions.bits(),
                    host_run: c
                        .host_run
                        .as_ref()
                        .map(super::dock_host_run::HostRunAskDto::of),
                }),
            },
            None => Self::default(),
        }
    }
}

/// What an installed connector carries beyond a module; all absent for a WASM module.
#[derive(Serialize, Default)]
pub(in crate::http) struct ConnectorInstalledDto {
    #[serde(skip_serializing_if = "Option::is_none")]
    provider: Option<&'static str>,
    /// What the admin approved, the ceiling on its token.
    #[serde(skip_serializing_if = "Option::is_none")]
    connector_permissions: Option<i64>,
    /// The token, only in the install answer that created it.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) connector_token: Option<String>,
}

impl ConnectorInstalledDto {
    pub(super) fn of(approved: Option<Permissions>) -> Self {
        match approved {
            Some(p) => Self {
                provider: Some(super::manifest::connector::CONNECTOR),
                connector_permissions: Some(p.bits()),
                connector_token: None,
            },
            None => Self::default(),
        }
    }
}

impl InstalledModuleDto {
    /// Adds a connector's token, legible only in the answer that minted it.
    pub(super) fn with_connector_token(mut self, token: Option<String>) -> Self {
        self.connector.connector_token = token;
        self
    }
}
