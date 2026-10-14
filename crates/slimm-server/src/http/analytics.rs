// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Space usage analytics: one resource, gated on MANAGE_SERVER same as
//! `/space/settings`, that reads as disabled rather than refusing outright
//! when the toggle is off. See `docs/decisions/0008-space-analytics.md`.
//!
//! **Rate limit**: `read` charges `Class::Write`, not the generous
//! `Class::AuthedRead` its three siblings below use, because
//! [`current_analytics`] runs real cross-table aggregation over the whole
//! message and attachment history rather than a single-row lookup - see its
//! own doc. `read_retention`, `read_canvas_cap`, and `read_screen_share_cap`
//! each read one config value, the same shape `/space/settings`'s own read
//! does, so they stay on `AuthedRead`.

use axum::Router;
use axum::extract::{DefaultBodyLimit, Query, State};
use axum::http::request::Parts;
use axum::routing::get;
use serde::{Deserialize, Serialize};

use super::AppState;
use super::error::ApiError;
use super::extract::require_manage_server;
use super::extract::{Authed, Json, enforce};
use crate::process_metrics::current_rss_bytes;
use crate::ratelimit::Class;
use crate::store::{
    AnalyticsStats, MAX_CANVAS_OBJECT_CAP, MAX_MESSAGE_RETENTION_DAYS, MAX_SCREEN_SHARE_MAX_HEIGHT,
    MIN_CANVAS_OBJECT_CAP, MIN_SCREEN_SHARE_MAX_HEIGHT, MemberAttachmentUsage,
};

const BODY_LIMIT: usize = 256;

/// The Space analytics and retention routes, mounted by [`super::router`].
///
/// Retention, the canvas object cap, and the screen-share height ceiling all
/// live here rather than under `/space/settings`: all four are
/// operator-facing resource-pressure tooling gated identically on
/// MANAGE_SERVER, so this keeps them together rather than splitting them
/// across files that would otherwise carry no other relationship. Retention
/// bounds disk; the canvas cap bounds every client's memory and paint on a
/// busy canvas; the screen-share ceiling bounds the load a share puts on
/// every client and the SFU. The last is client-advertised only - see
/// [`ScreenShareCapDto`] - so unlike the other two it has no server-side
/// enforcement of its own.
pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/space/analytics", get(read).patch(update))
        .route(
            "/space/retention",
            get(read_retention).patch(update_retention),
        )
        .route("/space/retention/preview", get(preview_retention))
        .route(
            "/space/canvas-cap",
            get(read_canvas_cap).patch(update_canvas_cap),
        )
        .route(
            "/space/screen-share",
            get(read_screen_share_cap).patch(update_screen_share_cap),
        )
        .layer(DefaultBodyLimit::max(BODY_LIMIT))
}

#[derive(Serialize)]
struct DayCountDto {
    date: String,
    count: i64,
}

#[derive(Serialize)]
struct MetricSampleDto {
    sampled_at: i64,
    rss_bytes: i64,
}

#[derive(Serialize)]
struct AnalyticsStatsDto {
    total_messages: i64,
    member_count: i64,
    channel_count: i64,
    attachment_bytes: i64,
    messages_by_day: Vec<DayCountDto>,
    active_hours: [i64; 24],
    memory_samples: Vec<MetricSampleDto>,
}

impl From<AnalyticsStats> for AnalyticsStatsDto {
    fn from(stats: AnalyticsStats) -> Self {
        Self {
            total_messages: stats.total_messages,
            member_count: stats.member_count,
            channel_count: stats.channel_count,
            attachment_bytes: stats.attachment_bytes,
            messages_by_day: stats
                .messages_by_day
                .into_iter()
                .map(|d| DayCountDto {
                    date: d.date,
                    count: d.count,
                })
                .collect(),
            active_hours: stats.active_hours,
            memory_samples: stats
                .memory_samples
                .into_iter()
                .map(|s| MetricSampleDto {
                    sampled_at: s.sampled_at,
                    rss_bytes: s.rss_bytes,
                })
                .collect(),
        }
    }
}

/// One member's attachment byte total. Never reachable through `stats`; see
/// [`MemberAttachmentUsage`]'s own doc for why this is a separate field.
#[derive(Serialize)]
struct MemberStorageDto {
    user_id: String,
    attachment_bytes: i64,
}

impl From<MemberAttachmentUsage> for MemberStorageDto {
    fn from(usage: MemberAttachmentUsage) -> Self {
        Self {
            user_id: usage.user_id.to_string(),
            attachment_bytes: usage.attachment_bytes,
        }
    }
}

/// `stats` and `member_storage` are present only when `enabled` is true: a
/// disabled deployment answers 200 with nothing computed, rather than a 403
/// or 404 a client would have to special-case apart from a real permission
/// or routing failure. The two are siblings, never nested, on purpose: see
/// [`MemberAttachmentUsage`]'s own doc for the privacy line between them.
#[derive(Serialize)]
struct AnalyticsDto {
    enabled: bool,
    stats: Option<AnalyticsStatsDto>,
    member_storage: Option<Vec<MemberStorageDto>>,
}

#[derive(Deserialize)]
struct UpdateAnalyticsDto {
    enabled: bool,
}

async fn read(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
) -> Result<Json<AnalyticsDto>, ApiError> {
    // Write, not AuthedRead: current_analytics does real cross-table aggregation.
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    require_manage_server(&state, ctx.user_id).await?;
    Ok(Json(current_analytics(&state).await?))
}

async fn update(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    Json(body): Json<UpdateAnalyticsDto>,
) -> Result<Json<AnalyticsDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    require_manage_server(&state, ctx.user_id).await?;
    state.store.set_analytics_enabled(body.enabled).await?;
    Ok(Json(current_analytics(&state).await?))
}

/// Samples this process's own memory on the way past, only when the toggle
/// is on: an admin with analytics off must add nothing to what runs.
async fn current_analytics(state: &AppState) -> Result<AnalyticsDto, ApiError> {
    let enabled = state.store.analytics_enabled().await?;
    if !enabled {
        return Ok(AnalyticsDto {
            enabled: false,
            stats: None,
            member_storage: None,
        });
    }
    if let Some(rss) = current_rss_bytes() {
        state.store.maybe_record_metrics_sample(rss).await?;
    }
    let stats = state.store.analytics_stats().await?;
    let member_storage = state.store.member_attachment_bytes().await?;
    Ok(AnalyticsDto {
        enabled: true,
        stats: Some(stats.into()),
        member_storage: Some(member_storage.into_iter().map(Into::into).collect()),
    })
}

#[derive(Serialize, Deserialize)]
struct RetentionDto {
    /// Days a message is kept before the sweep prunes it. `0` means
    /// disabled - keep forever, the default.
    retention_days: i64,
}

async fn read_retention(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
) -> Result<Json<RetentionDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::AuthedRead)?;
    require_manage_server(&state, ctx.user_id).await?;
    Ok(Json(RetentionDto {
        retention_days: state.store.message_retention_days().await?,
    }))
}

#[derive(Deserialize)]
struct RetentionPreviewQuery {
    days: i64,
}

/// What a window would prune right now; the admin screen asks before saving.
#[derive(Serialize)]
struct RetentionPreviewDto {
    retention_days: i64,
    messages: i64,
}

async fn preview_retention(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    Query(query): Query<RetentionPreviewQuery>,
) -> Result<Json<RetentionPreviewDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::AuthedRead)?;
    require_manage_server(&state, ctx.user_id).await?;
    if !(0..=MAX_MESSAGE_RETENTION_DAYS).contains(&query.days) {
        return Err(ApiError::BadRequest("days out of range"));
    }
    Ok(Json(RetentionPreviewDto {
        retention_days: query.days,
        messages: state
            .store
            .count_messages_past_retention(query.days)
            .await?,
    }))
}

/// A negative or absurdly large window is refused rather than clamped, so a
/// typo cannot silently land on whichever bound the code happens to pick.
async fn update_retention(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    Json(body): Json<RetentionDto>,
) -> Result<Json<RetentionDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    require_manage_server(&state, ctx.user_id).await?;
    if !(0..=MAX_MESSAGE_RETENTION_DAYS).contains(&body.retention_days) {
        return Err(ApiError::BadRequest("retention_days out of range"));
    }
    state
        .store
        .set_message_retention_days(body.retention_days)
        .await?;
    Ok(Json(RetentionDto {
        retention_days: body.retention_days,
    }))
}

#[derive(Serialize, Deserialize)]
struct CanvasCapDto {
    /// Most live objects one channel's canvas may hold before a placement is
    /// refused. Applies to every client; lower it to keep a busy canvas light,
    /// raise it to allow denser boards at a memory-and-paint cost.
    object_cap: i64,
}

async fn read_canvas_cap(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
) -> Result<Json<CanvasCapDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::AuthedRead)?;
    require_manage_server(&state, ctx.user_id).await?;
    Ok(Json(CanvasCapDto {
        object_cap: state.store.canvas_object_cap().await?,
    }))
}

/// A cap outside the settable range is refused rather than clamped, so a typo
/// cannot silently land on whichever bound the code happens to pick - the same
/// rule [`update_retention`] follows.
async fn update_canvas_cap(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    Json(body): Json<CanvasCapDto>,
) -> Result<Json<CanvasCapDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    require_manage_server(&state, ctx.user_id).await?;
    if !(MIN_CANVAS_OBJECT_CAP..=MAX_CANVAS_OBJECT_CAP).contains(&body.object_cap) {
        return Err(ApiError::BadRequest("object_cap out of range"));
    }
    state.store.set_canvas_object_cap(body.object_cap).await?;
    Ok(Json(CanvasCapDto {
        object_cap: body.object_cap,
    }))
}

#[derive(Serialize, Deserialize)]
struct ScreenShareCapDto {
    /// The tallest resolution a screen share may publish at. Applies to
    /// every client: enforcement is client-advertised, not a server-side
    /// track inspection, so a client caps its own capture parameters before
    /// starting a share.
    max_height: i64,
}

async fn read_screen_share_cap(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
) -> Result<Json<ScreenShareCapDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::AuthedRead)?;
    require_manage_server(&state, ctx.user_id).await?;
    Ok(Json(ScreenShareCapDto {
        max_height: state.store.screen_share_max_height().await?,
    }))
}

/// A height outside the settable range is refused rather than clamped, so a
/// typo cannot silently land on whichever bound the code happens to pick -
/// the same rule [`update_canvas_cap`] follows.
async fn update_screen_share_cap(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    Json(body): Json<ScreenShareCapDto>,
) -> Result<Json<ScreenShareCapDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    require_manage_server(&state, ctx.user_id).await?;
    if !(MIN_SCREEN_SHARE_MAX_HEIGHT..=MAX_SCREEN_SHARE_MAX_HEIGHT).contains(&body.max_height) {
        return Err(ApiError::BadRequest("max_height out of range"));
    }
    state
        .store
        .set_screen_share_max_height(body.max_height)
        .await?;
    Ok(Json(ScreenShareCapDto {
        max_height: body.max_height,
    }))
}
