// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A module's declared settings and the values an admin gives them (decision
//! 0091). A sibling of `dock_lifecycle` so `tests/openapi_429_coverage.rs`
//! resolves the handlers. A secret's value is never sent back, only whether it is set.

use std::collections::BTreeMap;

use axum::extract::{Path, State};
use axum::http::request::Parts;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::super::AppState;
use super::super::error::ApiError;
use super::super::extract::require_manage_server;
use super::super::extract::{Authed, Json, enforce};
use crate::ratelimit::Class;
use crate::store::{InstalledModule, ModuleSettingDef, SettingKind};

#[derive(Serialize)]
pub(in crate::http) struct SettingsResponse {
    settings: Vec<SettingView>,
}

#[derive(Serialize)]
struct SettingView {
    #[serde(flatten)]
    def: ModuleSettingDef,
    /// The stored value, else the default; for a secret `{"set": bool}`.
    #[serde(skip_serializing_if = "Option::is_none")]
    value: Option<Value>,
}

#[derive(Deserialize)]
pub(in crate::http) struct PutSettingsRequest {
    values: BTreeMap<String, Value>,
}

pub(in crate::http) async fn get_settings(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    Path(id): Path<String>,
) -> Result<Json<SettingsResponse>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::AuthedRead)?;
    require_manage_server(&state, ctx.user_id).await?;
    let module = installed(&state, &id).await?;
    Ok(Json(view(&state, &module).await?))
}

pub(in crate::http) async fn put_settings(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    Path(id): Path<String>,
    Json(req): Json<PutSettingsRequest>,
) -> Result<Json<SettingsResponse>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    require_manage_server(&state, ctx.user_id).await?;
    let module = installed(&state, &id).await?;
    let changes = validated_changes(&module.settings_schema, req.values)?;
    state
        .store
        .apply_module_settings(&id, &module.settings_schema, &changes)
        .await?;
    state.dock.slot_cache().invalidate_module(&id);
    Ok(Json(view(&state, &module).await?))
}

async fn installed(state: &AppState, id: &str) -> Result<InstalledModule, ApiError> {
    state
        .store
        .installed_module(id)
        .await?
        .ok_or(ApiError::NotFound("module not installed"))
}

/// `null` clears; anything else must suit its definition. Unknown keys are refused.
fn validated_changes(
    defs: &[ModuleSettingDef],
    values: BTreeMap<String, Value>,
) -> Result<Vec<(String, Option<Value>)>, ApiError> {
    let mut changes = Vec::with_capacity(values.len());
    for (key, value) in values {
        let def = defs
            .iter()
            .find(|d| d.key == key)
            .ok_or_else(|| ApiError::BadRequestDetail(format!("unknown setting: {key}")))?;
        if value.is_null() {
            changes.push((key, None));
            continue;
        }
        def.check_value(&value)
            .map_err(|why| ApiError::BadRequestDetail(format!("setting {key} {why}")))?;
        changes.push((key, Some(value)));
    }
    Ok(changes)
}

async fn view(state: &AppState, module: &InstalledModule) -> Result<SettingsResponse, ApiError> {
    let stored = state.store.module_setting_values(&module.id).await?;
    let set = state.store.module_setting_keys_set(&module.id).await?;
    let settings = module
        .settings_schema
        .iter()
        .map(|def| {
            let value = if def.kind == SettingKind::Secret {
                Some(json!({ "set": set.contains(&def.key) }))
            } else {
                stored.get(&def.key).or(def.default.as_ref()).cloned()
            };
            SettingView {
                def: def.clone(),
                value,
            }
        })
        .collect();
    Ok(SettingsResponse { settings })
}
