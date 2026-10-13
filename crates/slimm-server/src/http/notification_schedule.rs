// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The notification schedule (`docs/decisions/0033-notification-schedule.md`):
//! a per-weekday on-hours window, an off-hours policy, two allow-lists, and
//! an optional snooze. Enforced exactly once, in
//! `push::recipients::narrow_for_notification_preference`, the same choke
//! point the old `/push/quiet-hours` window used - never a filter a client
//! applies after a device has already buzzed.
//!
//! `/push/quiet-hours` (`http/quiet_hours.rs`) is untouched and still reads
//! and writes its own columns; only push enforcement moved to this model,
//! and migration 0081 seeded every existing quiet-hours user into it so
//! nobody's push changed on upgrade.

use axum::Router;
use axum::extract::DefaultBodyLimit;
use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::http::request::Parts;
use axum::routing::{get, put};
use serde::{Deserialize, Serialize};

use super::AppState;
use super::error::ApiError;
use super::extract::{AUTHED_READ, Authed, AuthedLimited, Json, enforce};
use super::messages::parse_uuid;
use crate::ids::{ChannelId, UserId};
use crate::notification_schedule::{DayWindow, OffHoursMode, WEEKDAYS};
use crate::permissions::Permissions;
use crate::ratelimit::Class;
use crate::store::{DaySetting, NotificationScheduleDetail};

/// A snooze may not outlast a week: long enough for "until Monday" from any
/// day, short enough that an account can never lock its own notifications
/// off forever by mistake with no UI left to undo it from.
const MAX_SNOOZE_MS: i64 = 7 * 24 * 60 * 60 * 1000;

/// Every body here is a small JSON document; refused well before axum's 2 MB default.
const BODY_LIMIT: usize = 64 * 1024;

/// The notification-schedule routes, mounted by [`super::router`].
pub fn routes() -> Router<AppState> {
    Router::new()
        .route(
            "/notifications/schedule",
            get(get_schedule).put(set_schedule).delete(clear_schedule),
        )
        .route(
            "/notifications/schedule/allowed-users/{user_id}",
            put(add_allowed_user).delete(remove_allowed_user),
        )
        .route(
            "/notifications/schedule/allowed-channels/{channel_id}",
            put(add_allowed_channel).delete(remove_allowed_channel),
        )
        .route(
            "/notifications/schedule/snooze",
            put(set_snooze).delete(clear_snooze),
        )
        .layer(DefaultBodyLimit::max(BODY_LIMIT))
}

// --- Wire types ---

#[derive(Serialize, Deserialize)]
struct DayWindowDto {
    weekday: u8,
    start_minute: i64,
    end_minute: i64,
}

#[derive(Serialize)]
struct NotificationScheduleDto {
    timezone: String,
    days: Vec<DayWindowDto>,
    off_hours_mode: String,
    snooze_until: Option<i64>,
    allowed_user_ids: Vec<String>,
    allowed_channel_ids: Vec<String>,
}

#[derive(Serialize)]
struct NotificationScheduleResponse {
    /// `null` means never configured - see `store/notification_schedule.rs`'s
    /// own doc comment for why that is distinct from a schedule with every
    /// day empty.
    schedule: Option<NotificationScheduleDto>,
}

impl From<NotificationScheduleDetail> for NotificationScheduleDto {
    fn from(detail: NotificationScheduleDetail) -> Self {
        let days = detail
            .schedule
            .days
            .iter()
            .enumerate()
            .filter_map(|(weekday, window)| {
                window.map(|w| DayWindowDto {
                    weekday: weekday as u8,
                    start_minute: i64::from(w.start_minute),
                    end_minute: i64::from(w.end_minute),
                })
            })
            .collect();
        Self {
            timezone: detail.schedule.timezone,
            days,
            off_hours_mode: detail.schedule.off_hours_mode.as_str().to_owned(),
            snooze_until: detail.schedule.snooze_until,
            allowed_user_ids: detail
                .allowed_user_ids
                .iter()
                .map(UserId::to_string)
                .collect(),
            allowed_channel_ids: detail
                .allowed_channel_ids
                .iter()
                .map(ChannelId::to_string)
                .collect(),
        }
    }
}

#[derive(Deserialize)]
struct SetScheduleRequest {
    timezone: String,
    days: Vec<DayWindowDto>,
    off_hours_mode: String,
}

#[derive(Deserialize)]
struct SnoozeRequest {
    until_ms: i64,
}

#[derive(Serialize)]
struct SnoozeResponse {
    snooze_until: Option<i64>,
}

// --- Handlers ---

async fn get_schedule(
    AuthedLimited(ctx): AuthedLimited<AUTHED_READ>,
    State(state): State<AppState>,
) -> Result<Json<NotificationScheduleResponse>, ApiError> {
    let detail = state.store.notification_schedule(ctx.user_id).await?;
    Ok(Json(NotificationScheduleResponse {
        schedule: detail.map(Into::into),
    }))
}

/// Replaces the caller's own timezone, off-hours mode and weekly windows.
/// `timezone` must be a resolvable IANA name; a per-day window follows
/// [`DayWindow::parse`]'s own bounds, and a weekday may appear at most once.
async fn set_schedule(
    Authed(ctx): Authed,
    parts: Parts,
    State(state): State<AppState>,
    Json(req): Json<SetScheduleRequest>,
) -> Result<Json<NotificationScheduleResponse>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;

    if jiff::tz::TimeZone::get(&req.timezone).is_err() {
        return Err(ApiError::BadRequest(
            "timezone must be a resolvable IANA time zone name",
        ));
    }
    let off_hours_mode = OffHoursMode::parse(&req.off_hours_mode).ok_or(ApiError::BadRequest(
        "off_hours_mode must be \"mentions\" or \"nothing\"",
    ))?;

    let mut seen = [false; WEEKDAYS];
    let mut days = Vec::with_capacity(req.days.len());
    for day in &req.days {
        if day.weekday as usize >= WEEKDAYS {
            return Err(ApiError::BadRequest(
                "weekday must be 0 (Monday) to 6 (Sunday)",
            ));
        }
        if std::mem::replace(&mut seen[day.weekday as usize], true) {
            return Err(ApiError::BadRequest("a weekday may appear at most once"));
        }
        let window =
            DayWindow::parse(day.start_minute, day.end_minute).ok_or(ApiError::BadRequest(
                "start_minute and end_minute must each be 0 to 1439 and must differ",
            ))?;
        days.push(DaySetting {
            weekday: day.weekday,
            window,
        });
    }

    state
        .store
        .set_notification_schedule(ctx.user_id, &req.timezone, off_hours_mode, &days)
        .await?;
    let detail = state
        .store
        .notification_schedule(ctx.user_id)
        .await?
        .ok_or(ApiError::Internal)?;
    Ok(Json(NotificationScheduleResponse {
        schedule: Some(detail.into()),
    }))
}

async fn clear_schedule(
    Authed(ctx): Authed,
    parts: Parts,
    State(state): State<AppState>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    state.store.clear_notification_schedule(ctx.user_id).await?;
    Ok(StatusCode::NO_CONTENT)
}

/// The member card's "notify me about this person off-hours" action.
async fn add_allowed_user(
    Authed(ctx): Authed,
    parts: Parts,
    Path(user_id): Path<String>,
    State(state): State<AppState>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let allowed_user_id = UserId(parse_uuid(&user_id)?);
    if state.store.user_profile(allowed_user_id).await?.is_none() {
        return Err(ApiError::NotFound("no such member"));
    }
    state
        .store
        .add_notification_schedule_allowed_user(ctx.user_id, allowed_user_id)
        .await?;
    Ok(StatusCode::NO_CONTENT)
}

async fn remove_allowed_user(
    Authed(ctx): Authed,
    parts: Parts,
    Path(user_id): Path<String>,
    State(state): State<AppState>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let allowed_user_id = UserId(parse_uuid(&user_id)?);
    state
        .store
        .remove_notification_schedule_allowed_user(ctx.user_id, allowed_user_id)
        .await?;
    Ok(StatusCode::NO_CONTENT)
}

/// The channel menu's "notify me off-hours here" action. Requires
/// `VIEW_CHANNEL`, the same bar `channel_notification_prefs::set` already
/// sets for muting a channel - allow-listing one should need no more.
async fn add_allowed_channel(
    Authed(ctx): Authed,
    parts: Parts,
    Path(channel_id): Path<String>,
    State(state): State<AppState>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let channel_id = ChannelId(parse_uuid(&channel_id)?);
    if !state
        .store
        .has_permission(ctx.user_id, channel_id, Permissions::VIEW_CHANNEL)
        .await?
    {
        return Err(ApiError::Forbidden);
    }
    state
        .store
        .add_notification_schedule_allowed_channel(ctx.user_id, channel_id)
        .await?;
    Ok(StatusCode::NO_CONTENT)
}

async fn remove_allowed_channel(
    Authed(ctx): Authed,
    parts: Parts,
    Path(channel_id): Path<String>,
    State(state): State<AppState>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let channel_id = ChannelId(parse_uuid(&channel_id)?);
    state
        .store
        .remove_notification_schedule_allowed_channel(ctx.user_id, channel_id)
        .await?;
    Ok(StatusCode::NO_CONTENT)
}

/// Pauses notifications until `until_ms`, Slack's "30m / 1h / until
/// tomorrow" - the client computes the concrete deadline for each of those
/// (only it knows the account's own local midnight), and this only bounds
/// how far out that deadline may be.
async fn set_snooze(
    Authed(ctx): Authed,
    parts: Parts,
    State(state): State<AppState>,
    Json(req): Json<SnoozeRequest>,
) -> Result<Json<SnoozeResponse>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let now = crate::store::now_ms();
    if req.until_ms <= now || req.until_ms - now > MAX_SNOOZE_MS {
        return Err(ApiError::BadRequest(
            "until_ms must be in the future and no more than a week out",
        ));
    }
    state
        .store
        .set_notification_snooze(ctx.user_id, Some(req.until_ms))
        .await?;
    Ok(Json(SnoozeResponse {
        snooze_until: Some(req.until_ms),
    }))
}

async fn clear_snooze(
    Authed(ctx): Authed,
    parts: Parts,
    State(state): State<AppState>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    state
        .store
        .set_notification_snooze(ctx.user_id, None)
        .await?;
    Ok(StatusCode::NO_CONTENT)
}
