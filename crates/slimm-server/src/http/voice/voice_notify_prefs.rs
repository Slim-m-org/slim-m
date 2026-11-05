// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A member's opt-in to hear when a voice channel's call starts, grows or goes live
//! (`GET /voice-notifications/channels`, `PUT /voice-notifications/channels/{id}`, decision 0107).

use axum::Router;
use axum::extract::DefaultBodyLimit;
use axum::extract::{Path, State};
use axum::http::request::Parts;
use axum::routing::{get, put};
use serde::{Deserialize, Serialize};

use super::super::AppState;
use super::super::error::ApiError;
use super::super::extract::{AUTHED_READ, Authed, AuthedLimited, Json, enforce};
use super::super::messages::parse_uuid;
use crate::ids::ChannelId;
use crate::permissions::Permissions;
use crate::ratelimit::Class;
use crate::voice_notify::{JoinMode, VoiceNotifyChoice};

/// Every body here is one tiny JSON document.
const BODY_LIMIT: usize = 4 * 1024;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/voice-notifications/channels", get(list))
        .route("/voice-notifications/channels/{channel_id}", put(set))
        .layer(DefaultBodyLimit::max(BODY_LIMIT))
}

#[derive(Serialize)]
struct ChoiceDto {
    channel_id: String,
    joins: String,
    streams: bool,
}

#[derive(Deserialize)]
struct SetRequest {
    joins: String,
    streams: bool,
}

/// Every channel the caller switched something on for; a channel left off carries no entry.
async fn list(
    AuthedLimited(ctx): AuthedLimited<AUTHED_READ>,
    State(state): State<AppState>,
) -> Result<Json<Vec<ChoiceDto>>, ApiError> {
    let rows = state.store.list_voice_notify_choices(ctx.user_id).await?;
    Ok(Json(
        rows.into_iter()
            .map(|(channel_id, choice)| dto(channel_id, choice))
            .collect(),
    ))
}

/// Replaces the caller's choice for one voice channel; off with no streaming clears it.
/// Needs `VIEW_CHANNEL`, the same bar the call's own roster sets.
async fn set(
    Authed(ctx): Authed,
    parts: Parts,
    Path(channel_id): Path<String>,
    State(state): State<AppState>,
    Json(req): Json<SetRequest>,
) -> Result<Json<ChoiceDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let channel_id = ChannelId(parse_uuid(&channel_id)?);
    let joins = JoinMode::parse(&req.joins)
        .ok_or(ApiError::BadRequest("joins must be off, first or every"))?;
    if !state
        .store
        .has_permission(ctx.user_id, channel_id, Permissions::VIEW_CHANNEL)
        .await?
    {
        return Err(ApiError::Forbidden);
    }
    let is_voice = state
        .store
        .channel(channel_id)
        .await?
        .is_some_and(|c| c.kind == "voice" && c.parent_message_id.is_none());
    if !is_voice {
        return Err(ApiError::BadRequest("that is not a voice channel"));
    }
    let choice = VoiceNotifyChoice {
        joins,
        streams: req.streams,
    };
    state
        .store
        .set_voice_notify_choice(ctx.user_id, channel_id, choice)
        .await?;
    Ok(Json(dto(channel_id, choice)))
}

fn dto(channel_id: ChannelId, choice: VoiceNotifyChoice) -> ChoiceDto {
    ChoiceDto {
        channel_id: channel_id.to_string(),
        joins: choice.joins.as_str().to_owned(),
        streams: choice.streams,
    }
}
