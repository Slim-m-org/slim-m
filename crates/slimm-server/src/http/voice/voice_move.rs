// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Moving someone from one voice call to another (decision 0071).

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::http::request::Parts;
use serde::Deserialize;

use super::super::AppState;
use super::super::error::ApiError;
use super::super::extract::{Authed, Json, enforce};
use super::super::messages::parse_uuid;
use crate::hub::Event;
use crate::ids::{ChannelId, UserId};
use crate::permissions::Permissions;
use crate::ratelimit::Class;
use crate::store::Channel;
use crate::voice::VoiceError;

#[derive(Deserialize)]
pub(super) struct MoveRequest {
    to_channel_id: String,
}

/// Needs `MOVE_MEMBERS` and `VIEW_CHANNEL` in both calls, and the person
/// to be on the source call and allowed into the destination.
pub(super) async fn move_participant(
    Authed(ctx): Authed,
    parts: Parts,
    Path((channel_id, user_id)): Path<(String, String)>,
    State(state): State<AppState>,
    Json(req): Json<MoveRequest>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let from_id = ChannelId(parse_uuid(&channel_id)?);
    let target = UserId(parse_uuid(&user_id)?);
    let to_id = ChannelId(parse_uuid(&req.to_channel_id)?);
    if from_id == to_id {
        return Err(ApiError::BadRequest("that person is already in this call"));
    }
    if !state.voice.is_enabled() {
        return Err(ApiError::NotConfigured(
            "this server has no voice configured",
        ));
    }

    let needed = Permissions::VIEW_CHANNEL.union(Permissions::MOVE_MEMBERS);
    for id in [from_id, to_id] {
        let held = state.store.permissions_in_channel(ctx.user_id, id).await?;
        if !held.contains(needed) {
            return Err(ApiError::Forbidden);
        }
    }
    let from = voice_channel(&state, from_id).await?;
    let to = voice_channel(&state, to_id).await?;

    let reachable = Permissions::VIEW_CHANNEL.union(Permissions::CONNECT);
    let target_held = state.store.permissions_in_channel(target, to_id).await?;
    if !target_held.contains(reachable) {
        return Err(ApiError::Conflict("that person cannot join that channel"));
    }

    let on_source = participants(&state, from_id).await?;
    if !on_source.contains(&target) {
        return Err(ApiError::Conflict("that person is not in this call"));
    }
    let on_destination = participants(&state, to_id).await?;
    if to.room.user_limit > 0 && on_destination.len() as i64 >= to.room.user_limit {
        return Err(ApiError::Conflict("that call is full"));
    }
    super::voice_rooms::check_join(&state, &to, target).await?;

    let mover = state.store.user_profile(ctx.user_id).await?;
    let moved_by_name = mover.map(|u| u.display_name).unwrap_or_default();
    state
        .store
        .record_voice_move(
            ctx.user_id,
            target,
            &format!("{} to {}", from.name, to.name),
        )
        .await?;
    state.hub.publish(Event::VoiceMoved {
        user_id: target,
        from_channel_id: from_id,
        to_channel_id: to_id,
        to_channel_name: to.name,
        moved_by_id: ctx.user_id,
        moved_by_name,
    });

    match state.voice.remove_participant(from_id, target).await {
        Ok(()) => Ok(StatusCode::NO_CONTENT),
        Err(VoiceError::Unavailable) => Err(ApiError::NotConfigured(
            "this server has no voice configured",
        )),
        Err(VoiceError::Internal(err)) => {
            tracing::warn!(%err, "could not take a moved participant out of their call");
            Err(ApiError::Unavailable)
        }
    }
}

async fn voice_channel(state: &AppState, id: ChannelId) -> Result<Channel, ApiError> {
    state
        .store
        .channel(id)
        .await?
        .filter(|c| c.kind == "voice" && c.parent_message_id.is_none())
        .ok_or(ApiError::BadRequest("that is not a voice channel"))
}

async fn participants(state: &AppState, id: ChannelId) -> Result<Vec<UserId>, ApiError> {
    match state.voice.list_participants(id).await {
        Ok(list) => Ok(list.into_iter().map(|p| p.user_id).collect()),
        Err(VoiceError::Unavailable) => Err(ApiError::NotConfigured(
            "this server has no voice configured",
        )),
        Err(VoiceError::Internal(err)) => {
            tracing::warn!(%err, "could not list a voice call");
            Err(ApiError::Unavailable)
        }
    }
}
