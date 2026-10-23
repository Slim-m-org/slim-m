// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Uninstall, enable, disable and list for installed modules, apart from the install
//! half in `dock.rs`. A sibling, not a child, so `tests/openapi_429_coverage.rs` resolves the handlers.

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::http::request::Parts;

use super::super::AppState;
use super::super::error::ApiError;
use super::super::extract::require_manage_server;
use super::super::extract::{Authed, Json, enforce};
use super::keywords::{self, ensure_slash_keywords_free};
use super::wire::InstalledModuleDto;
use crate::ratelimit::Class;
use crate::store::{DeleteAccountError, InstalledModule};

pub(in crate::http) async fn uninstall(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    Path(id): Path<String>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    require_manage_server(&state, ctx.user_id).await?;
    let module = state.store.installed_module(&id).await?;
    if !state.store.uninstall_module(&id).await? {
        return Err(ApiError::NotFound("module not installed"));
    }
    state.dock.slot_cache().invalidate_module(&id);
    if let Some(module) = module {
        retire_principal(&state, &module).await;
    }
    Ok(StatusCode::NO_CONTENT)
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
        Ok(_) | Err(DeleteAccountError::UserNotFound) => {
            super::super::members::announce_member_gone(state, bot).await;
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
/// `tests/openapi_429_coverage.rs`'s static scan, which reads a handler's own
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
        let keywords = keywords::slash_keywords(&module.extension_points);
        ensure_slash_keywords_free(state, id, keywords).await?;
    }
    if !state.store.set_module_enabled(id, enabled).await? {
        return Err(ApiError::NotFound("module not installed"));
    }
    state.dock.slot_cache().invalidate_module(id);
    let installed = state
        .store
        .installed_module(id)
        .await?
        .ok_or(ApiError::NotFound("module not installed"))?;
    Ok(Json(InstalledModuleDto::from(installed)))
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
    Ok(Json(
        modules
            .into_iter()
            .map(|m| {
                let stats = stats.remove(&m.id).unwrap_or_default();
                let usage = usage.get(&m.id).copied().unwrap_or_default();
                InstalledModuleDto::from(m).with_activity(stats, usage)
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
