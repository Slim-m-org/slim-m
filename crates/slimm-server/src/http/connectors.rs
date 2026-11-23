// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What a connector reads about itself with its own token (decision 0090):
//! which module it is, what it was approved, and its settings with the secret
//! values in plain text. Only that token reaches it: anyone else is refused,
//! and nothing here is logged.

use std::collections::BTreeMap;

use axum::Router;
use axum::extract::State;
use axum::http::header::{CACHE_CONTROL, HeaderValue};
use axum::http::request::Parts;
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use serde::Serialize;
use serde_json::Value;

use super::AppState;
use super::error::ApiError;
use super::extract::{Authed, Json, enforce};
use crate::ratelimit::Class;
use crate::store::{InstalledModule, SettingKind};

pub fn routes() -> Router<AppState> {
    Router::new().route("/connectors/me", get(me))
}

#[derive(Serialize)]
struct ConnectorSelfDto {
    module_id: String,
    name: String,
    version: String,
    /// The ceiling on this token, as the admin approved it.
    permissions: i64,
    /// Every declared setting: the stored value, else its default, else `null`. Secrets in plain text.
    settings: BTreeMap<String, Value>,
}

async fn me(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
) -> Result<Response, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::AuthedRead)?;
    let module = state
        .store
        .connector_of(ctx.user_id)
        .await?
        .ok_or(ApiError::ForbiddenBecause(
            "only a connector's own token can read it",
        ))?;
    if !module.enabled {
        return Err(ApiError::Conflict("an admin has turned this connector off"));
    }
    let body = ConnectorSelfDto {
        settings: settings(&state, &module).await?,
        permissions: module.connector_permissions.unwrap_or_default().bits(),
        module_id: module.id,
        name: module.name,
        version: module.version,
    };
    let mut response = Json(body).into_response();
    response
        .headers_mut()
        .insert(CACHE_CONTROL, HeaderValue::from_static("no-store"));
    Ok(response)
}

async fn settings(
    state: &AppState,
    module: &InstalledModule,
) -> Result<BTreeMap<String, Value>, ApiError> {
    let mut stored = state.store.module_setting_values(&module.id).await?;
    let mut out = BTreeMap::new();
    for def in &module.settings_schema {
        let value = match def.kind {
            SettingKind::Secret => state
                .store
                .module_secret(&module.id, &def.key)
                .await
                .map(Value::String),
            _ => stored.remove(&def.key).or_else(|| def.default.clone()),
        };
        out.insert(def.key.clone(), value.unwrap_or(Value::Null));
    }
    Ok(out)
}
