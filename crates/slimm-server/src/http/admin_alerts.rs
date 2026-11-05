// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The operator alert list and the caller's own mute, both for holders of `MANAGE_SERVER`.
//! What raises an alert is `crate::admin_alerts`.

use axum::Router;
use axum::extract::{DefaultBodyLimit, State};
use axum::http::request::Parts;
use axum::routing::{get, put};
use serde::{Deserialize, Serialize};

use super::AppState;
use super::error::ApiError;
use super::extract::{AUTHED_READ, Authed, AuthedLimited, Json, enforce, require_manage_server};
use crate::admin_alerts::RECOVERED_VISIBLE_MS;
use crate::ratelimit::Class;
use crate::store::{AdminAlert, now_ms};

const BODY_LIMIT: usize = 1024;

/// The alert routes, mounted by [`super::router`].
pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/space/alerts", get(list))
        .route("/space/alerts/mute", put(set_mute))
        .layer(DefaultBodyLimit::max(BODY_LIMIT))
}

#[derive(Serialize)]
struct AdminAlertDto {
    kind: String,
    subject: String,
    detail: String,
    raised_at: i64,
    /// `null` while the condition lasts.
    resolved_at: Option<i64>,
}

impl From<AdminAlert> for AdminAlertDto {
    fn from(alert: AdminAlert) -> Self {
        Self {
            kind: alert.kind,
            subject: alert.subject,
            detail: alert.detail,
            raised_at: alert.raised_at,
            resolved_at: alert.resolved_at,
        }
    }
}

#[derive(Serialize)]
struct AdminAlertsDto {
    alerts: Vec<AdminAlertDto>,
    muted: bool,
}

#[derive(Deserialize)]
struct SetMuteRequest {
    muted: bool,
}

async fn snapshot(
    state: &AppState,
    user_id: crate::ids::UserId,
) -> Result<AdminAlertsDto, ApiError> {
    let alerts = state
        .store
        .list_admin_alerts(now_ms() - RECOVERED_VISIBLE_MS)
        .await?;
    Ok(AdminAlertsDto {
        alerts: alerts.into_iter().map(Into::into).collect(),
        muted: state.store.admin_alerts_muted(user_id).await?,
    })
}

async fn list(
    AuthedLimited(ctx): AuthedLimited<AUTHED_READ>,
    State(state): State<AppState>,
) -> Result<Json<AdminAlertsDto>, ApiError> {
    require_manage_server(&state, ctx.user_id).await?;
    Ok(Json(snapshot(&state, ctx.user_id).await?))
}

async fn set_mute(
    Authed(ctx): Authed,
    parts: Parts,
    State(state): State<AppState>,
    Json(req): Json<SetMuteRequest>,
) -> Result<Json<AdminAlertsDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    require_manage_server(&state, ctx.user_id).await?;
    state
        .store
        .set_admin_alerts_muted(ctx.user_id, req.muted)
        .await?;
    Ok(Json(snapshot(&state, ctx.user_id).await?))
}
