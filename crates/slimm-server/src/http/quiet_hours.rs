// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The account-wide quiet-hours window: an optional time-of-day span,
//! entered in local time by the client and sent here already converted to
//! minutes since midnight UTC, so the server never needs to know the
//! account's time zone.
//!
//! Legacy: nothing reads this window to decide push any more. Since
//! decision 0033 `push::recipients` reads only the notification schedule
//! (`notification_schedule.rs`), so these routes keep answering for older
//! clients but a window set here changes nothing about a live account's push.

use axum::Router;
use axum::extract::State;
use axum::http::StatusCode;
use axum::http::request::Parts;
use axum::routing::get;
use serde::{Deserialize, Serialize};

use super::AppState;
use super::error::ApiError;
use super::extract::{AUTHED_READ, Authed, AuthedLimited, Json, enforce};
use crate::notifications::QuietHours;
use crate::ratelimit::Class;

/// The quiet-hours routes, mounted by [`super::router`].
pub fn routes() -> Router<AppState> {
    Router::new().route(
        "/push/quiet-hours",
        get(get_quiet_hours).put(set).delete(clear),
    )
}

// --- Wire types ---

#[derive(Serialize, Deserialize)]
struct QuietHoursDto {
    start_minute: i64,
    end_minute: i64,
}

#[derive(Serialize)]
struct QuietHoursResponseDto {
    /// `null` when disabled, the default, and what every account that
    /// predates this feature keeps on upgrade.
    quiet_hours: Option<QuietHoursDto>,
}

impl From<QuietHours> for QuietHoursDto {
    fn from(window: QuietHours) -> Self {
        Self {
            start_minute: i64::from(window.start_minute),
            end_minute: i64::from(window.end_minute),
        }
    }
}

// --- Handlers ---

/// Reads the caller's own window back, a genuine round trip rather than a
/// local echo, the same reasoning `GET /push/preference` documents.
async fn get_quiet_hours(
    AuthedLimited(ctx): AuthedLimited<AUTHED_READ>,
    State(state): State<AppState>,
) -> Result<Json<QuietHoursResponseDto>, ApiError> {
    let quiet_hours = state.store.quiet_hours(ctx.user_id).await?;
    Ok(Json(QuietHoursResponseDto {
        quiet_hours: quiet_hours.map(Into::into),
    }))
}

/// Sets the caller's own window. `start_minute` may be greater than
/// `end_minute` for a window that crosses midnight - 23:00-08:00 is the
/// ordinary shape, not an edge case - so this refuses only an out-of-range
/// or equal pair, never one where start comes numerically after end.
async fn set(
    Authed(ctx): Authed,
    parts: Parts,
    State(state): State<AppState>,
    Json(req): Json<QuietHoursDto>,
) -> Result<Json<QuietHoursDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let quiet_hours = QuietHours::parse(req.start_minute, req.end_minute).ok_or(
        ApiError::BadRequest("start_minute and end_minute must each be 0 to 1439 and must differ"),
    )?;

    if !state
        .store
        .set_quiet_hours(ctx.user_id, Some(quiet_hours))
        .await?
    {
        return Err(ApiError::Unauthorized);
    }
    Ok(Json(quiet_hours.into()))
}

/// Clears the caller's own window, reverting to no quiet hours at all -
/// the same "no row/no value means the least restrictive answer" default
/// every notification-preference setting in this crate keeps on upgrade.
async fn clear(
    Authed(ctx): Authed,
    parts: Parts,
    State(state): State<AppState>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    if !state.store.set_quiet_hours(ctx.user_id, None).await? {
        return Err(ApiError::Unauthorized);
    }
    Ok(StatusCode::NO_CONTENT)
}
