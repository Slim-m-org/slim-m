// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A channel's own message retention, overriding the Space's window.
//!
//! Gated on MANAGE_SERVER like the Space setting, not MANAGE_CHANNELS: a
//! channel set to keep forever is an exemption from the Space's policy, so
//! only whoever owns that policy may grant it. A thread follows its parent
//! and a DM follows the Space, so neither takes an override of its own.
use axum::Router;
use axum::extract::{Path, Query, State};
use axum::http::request::Parts;
use axum::routing::get;
use serde::{Deserialize, Serialize};

use super::super::AppState;
use super::super::error::ApiError;
use super::super::extract::{Authed, Json, enforce, require_manage_server};
use super::super::messages::parse_uuid;
use crate::ids::ChannelId;
use crate::ratelimit::Class;
use crate::store::MAX_MESSAGE_RETENTION_DAYS;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/channels/{channel_id}/retention", get(read).put(update))
        .route("/channels/{channel_id}/retention/preview", get(preview))
}

/// `retention_days` is the channel's own window, or null when it follows the
/// Space; `space_retention_days` is that Space window, so a client can say
/// what "follow the Space" currently means.
#[derive(Serialize)]
struct ChannelRetentionDto {
    retention_days: Option<i64>,
    space_retention_days: i64,
}

#[derive(Deserialize)]
struct UpdateChannelRetention {
    retention_days: Option<i64>,
}

#[derive(Deserialize)]
struct PreviewQuery {
    days: i64,
}

#[derive(Serialize)]
struct ChannelRetentionPreviewDto {
    retention_days: i64,
    messages: i64,
}

/// The channel, once the caller may manage retention and it is one that can
/// carry its own window.
async fn retention_channel(
    state: &AppState,
    ctx_user: crate::ids::UserId,
    raw: &str,
) -> Result<ChannelId, ApiError> {
    require_manage_server(state, ctx_user).await?;
    let channel_id = ChannelId(parse_uuid(raw)?);
    let channel = state
        .store
        .channel(channel_id)
        .await?
        .ok_or(ApiError::NotFound("channel not found"))?;
    if channel.kind == "dm" || channel.parent_message_id.is_some() {
        return Err(ApiError::BadRequest(
            "a thread follows its channel and a DM follows the Space",
        ));
    }
    Ok(channel_id)
}

fn check_days(days: i64) -> Result<(), ApiError> {
    if (0..=MAX_MESSAGE_RETENTION_DAYS).contains(&days) {
        Ok(())
    } else {
        Err(ApiError::BadRequest("days out of range"))
    }
}

async fn dto(state: &AppState, channel_id: ChannelId) -> Result<ChannelRetentionDto, ApiError> {
    Ok(ChannelRetentionDto {
        retention_days: state.store.channel_retention_days(channel_id).await?,
        space_retention_days: state.store.message_retention_days().await?,
    })
}

async fn read(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    Path(channel_id): Path<String>,
) -> Result<Json<ChannelRetentionDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::AuthedRead)?;
    let channel_id = retention_channel(&state, ctx.user_id, &channel_id).await?;
    Ok(Json(dto(&state, channel_id).await?))
}

async fn update(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    Path(channel_id): Path<String>,
    Json(body): Json<UpdateChannelRetention>,
) -> Result<Json<ChannelRetentionDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let channel_id = retention_channel(&state, ctx.user_id, &channel_id).await?;
    if let Some(days) = body.retention_days {
        check_days(days)?;
    }
    state
        .store
        .set_channel_retention_days(channel_id, body.retention_days)
        .await?;
    Ok(Json(dto(&state, channel_id).await?))
}

/// What a window would prune in this channel and its threads right now; the
/// settings row asks before saving a shorter one.
async fn preview(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    Path(channel_id): Path<String>,
    Query(query): Query<PreviewQuery>,
) -> Result<Json<ChannelRetentionPreviewDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::AuthedRead)?;
    let channel_id = retention_channel(&state, ctx.user_id, &channel_id).await?;
    check_days(query.days)?;
    Ok(Json(ChannelRetentionPreviewDto {
        retention_days: query.days,
        messages: state
            .store
            .count_messages_past_channel_retention(channel_id, query.days)
            .await?,
    }))
}
