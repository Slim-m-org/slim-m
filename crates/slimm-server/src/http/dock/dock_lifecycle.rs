// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Uninstall, enable, disable and list for installed modules, apart from the install
//! half in `dock.rs`. A sibling, not a child, so `tests/it_infra/openapi_429_coverage.rs` resolves the handlers.

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::http::request::Parts;

use super::super::AppState;
use super::super::error::ApiError;
use super::super::extract::require_manage_server;
use super::super::extract::{Authed, Json, Query, enforce};
use super::super::overwrite_changes;
use super::super::overwrites::Target;
use super::capabilities::held_hooks;
use super::connector_guard;
use super::keywords::{self, ensure_slash_keywords_free};
use super::wire::InstalledModuleDto;
use crate::module_runtime::valid_file_id;
use crate::ratelimit::Class;
use crate::store::{DeleteAccountError, InstalledModule};

/// Module data files are kept on uninstall unless the admin asks for them gone.
#[derive(serde::Deserialize)]
pub(in crate::http) struct UninstallQuery {
    #[serde(default)]
    delete_data: bool,
}

pub(in crate::http) async fn uninstall(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    Path(id): Path<String>,
    Query(query): Query<UninstallQuery>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    require_manage_server(&state, ctx.user_id).await?;
    let module = state.store.installed_module(&id).await?;
    let runner = state.dock.host_run();
    let _no_pass = match &runner {
        Some(runner) => Some(runner.pause_monitor().await),
        None => None,
    };
    super::dock_host_run::before_uninstall(&state, &id, !query.delete_data).await?;
    let grants = connector_grants(&state, module.as_ref()).await?;
    let uninstalled = match module.as_ref().is_some_and(InstalledModule::is_connector) {
        true => uninstall_connector(&state, &id, ctx.user_id).await?,
        false => {
            state.store.uninstall_module(&id).await?
                || uninstall_connector(&state, &id, ctx.user_id).await?
        }
    };
    state.dock.slot_cache().invalidate_module(&id);
    crate::http::module_rooms::end_module(&state, &id);
    if uninstalled && let Some(grants) = grants {
        grants.announce(&state);
    }
    if uninstalled && let Some(module) = module {
        retire_principal(&state, &module).await;
    }
    // After the retirement, so a failed delete leaves a retry that only has files to remove.
    let mut found = uninstalled;
    if query.delete_data && (uninstalled || valid_file_id(&id)) {
        found |= delete_module_data(&state, &id).await?;
    }
    if !found {
        return Err(ApiError::NotFound("module not installed"));
    }
    Ok(StatusCode::NO_CONTENT)
}

/// What an uninstalled connector's principal held, read before the uninstall strips it.
struct ConnectorGrants {
    role: Option<crate::ids::RoleId>,
    overwrites: Vec<(crate::ids::ChannelId, Vec<crate::ids::UserId>)>,
}

impl ConnectorGrants {
    fn announce(self, state: &AppState) {
        connector_guard::announce_roles_changed(state, self.role);
        overwrite_changes::publish_changed(state, self.overwrites);
        state.hub.publish(crate::hub::Event::CategoryChanged);
    }
}

async fn connector_grants(
    state: &AppState,
    module: Option<&InstalledModule>,
) -> Result<Option<ConnectorGrants>, ApiError> {
    let Some(principal) = module
        .filter(|m| m.is_connector())
        .and_then(|m| m.bot_user_id)
    else {
        return Ok(None);
    };
    let channels = state.store.member_overwrite_channels(principal).await?;
    let overwrites =
        overwrite_changes::visible_before(state, &channels, &[Target::Member(principal)]).await?;
    Ok(Some(ConnectorGrants {
        role: connector_guard::managed_role(state, Some(principal)).await?,
        overwrites,
    }))
}

/// Revokes the connector's token and grants with its row, then closes the token's sockets.
async fn uninstall_connector(
    state: &AppState,
    id: &str,
    actor: crate::ids::UserId,
) -> Result<bool, ApiError> {
    let Some(revoked) = state.store.uninstall_connector(id, actor).await? else {
        return Ok(false);
    };
    super::dock_connector::close_sessions(state, revoked);
    Ok(true)
}

/// Removes a module's data files; `true` when there were any.
async fn delete_module_data(state: &AppState, id: &str) -> Result<bool, ApiError> {
    let files = state.dock.module_data(state.store.modules_dir());
    files.delete_data(id).await.map_err(|err| {
        tracing::warn!(%err, module = id, "could not delete a module's data");
        ApiError::Internal
    })
}

/// A scheduled module's principal and its channel overwrite go with the module,
/// so nothing ownerless stays in the member list or a channel's permissions.
/// Its messages stay, still labelled as the module's.
async fn retire_principal(state: &AppState, module: &InstalledModule) {
    let Some(bot) = module.bot_user_id else {
        return;
    };
    if let Some(channel) = module.schedule_channel_id
        && let Err(err) = state.store.delete_member_overwrite(channel, bot).await
    {
        tracing::warn!(%err, module = %module.id, "could not remove a module's channel overwrite");
    }
    match state.store.delete_account(bot).await {
        Ok(mut deleted) => {
            super::dock_connector::close_sessions(state, std::mem::take(&mut deleted.revoked));
            super::super::members::deleted_account::announce_deleted_account(state, bot, deleted)
                .await;
        }
        Err(DeleteAccountError::UserNotFound) => {
            super::super::members::announce_member_gone(state, bot, true).await;
        }
        Err(err) => {
            tracing::warn!(?err, module = %module.id, "could not remove a module's principal");
        }
    }
}

pub(in crate::http) async fn enable(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    Path(id): Path<String>,
) -> Result<Json<InstalledModuleDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    require_manage_server(&state, ctx.user_id).await?;
    apply_enabled(&state, &id, true).await
}

pub(in crate::http) async fn disable(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    Path(id): Path<String>,
) -> Result<Json<InstalledModuleDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    require_manage_server(&state, ctx.user_id).await?;
    apply_enabled(&state, &id, false).await
}

/// The shared body of [`enable`] and [`disable`] once the caller is already
/// authorized: each keeps its own `enforce`/`require_manage_server` call so
/// `tests/it_infra/openapi_429_coverage.rs`'s static scan, which reads a handler's own
/// body rather than following calls it makes, still sees the charge.
async fn apply_enabled(
    state: &AppState,
    id: &str,
    enabled: bool,
) -> Result<Json<InstalledModuleDto>, ApiError> {
    if enabled {
        let module = state
            .store
            .installed_module(id)
            .await?
            .ok_or(ApiError::NotFound("module not installed"))?;
        crate::http::module_compat::require_compatible(&module)?;
        let keywords = keywords::slash_keywords(&module.extension_points);
        ensure_slash_keywords_free(state, id, keywords).await?;
        super::dock_host_run::before_enable(state, id).await?;
    }
    if !state.store.set_module_enabled(id, enabled).await? {
        return Err(ApiError::NotFound("module not installed"));
    }
    state.dock.slot_cache().invalidate_module(id);
    announce_connector_grants(state, id).await?;
    if !enabled {
        crate::http::module_rooms::end_module(state, id);
        close_principal_sockets(state, id).await;
    }
    super::dock_host_run::after_enabled(state, id, enabled).await?;
    let installed = state
        .store
        .installed_module(id)
        .await?
        .ok_or(ApiError::NotFound("module not installed"))?;
    let health = state.store.module_health().await?.remove(id);
    let hooks = held_hooks(state, id).await?;
    Ok(Json(
        InstalledModuleDto::from(installed)
            .with_health(health.unwrap_or_default())
            .with_hooks(&hooks),
    ))
}

/// A connector's cap follows its enabled flag, so its principal's grants moved with the switch.
async fn announce_connector_grants(state: &AppState, id: &str) -> Result<(), ApiError> {
    let Some(module) = state.store.installed_module(id).await? else {
        return Ok(());
    };
    if module.is_connector() {
        let role = connector_guard::managed_role(state, module.bot_user_id).await?;
        connector_guard::announce_roles_changed(state, role);
    }
    Ok(())
}

/// Closes the sockets a disabled module's principal holds, so the off switch cuts its live feed.
async fn close_principal_sockets(state: &AppState, id: &str) {
    let principal = match state.store.installed_module(id).await {
        Ok(Some(module)) => module.bot_user_id,
        _ => None,
    };
    let Some(principal) = principal else {
        return;
    };
    match state.store.live_session_ids(principal).await {
        Ok(sessions) => super::dock_connector::close_sessions(state, sessions),
        Err(err) => tracing::warn!(
            ?err,
            module = id,
            "could not list a disabled module's sessions"
        ),
    }
}

pub(in crate::http) async fn list_installed(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
) -> Result<Json<Vec<InstalledModuleDto>>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::AuthedRead)?;
    require_manage_server(&state, ctx.user_id).await?;
    let modules = state.store.list_installed_modules().await?;
    let mut stats = state.store.module_run_stats().await?;
    let usage = state.store.module_storage_usage().await?;
    let mut health = state.store.module_health().await?;
    let mut hooks = state.store.module_hook_decls().await?;
    Ok(Json(
        modules
            .into_iter()
            .map(|m| {
                let stats = stats.remove(&m.id).unwrap_or_default();
                let usage = usage.get(&m.id).copied().unwrap_or_default();
                let health = health.remove(&m.id).unwrap_or_default();
                let depth = state.dock.queue_depths().get(&m.id);
                let hooks = hooks.remove(&m.id).unwrap_or_default();
                InstalledModuleDto::from(m)
                    .with_activity(stats, usage)
                    .with_health(health)
                    .with_queue_depth(depth)
                    .with_hooks(&hooks)
            })
            .collect(),
    ))
}

/// Empties a module's `kv.store`; the module stays installed with its approvals.
pub(in crate::http) async fn clear_storage(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    Path(id): Path<String>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    require_manage_server(&state, ctx.user_id).await?;
    match state.store.clear_module_storage(&id).await? {
        Some(_) => Ok(StatusCode::NO_CONTENT),
        None => Err(ApiError::NotFound("module not installed")),
    }
}
