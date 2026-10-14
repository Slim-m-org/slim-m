// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Temporary voice rooms (decision 0065): asking a lobby for a room, the
//! owner's three settings, the join check a lock or a limit adds, and
//! removing a room once its call is empty.

use std::sync::Arc;

use axum::Router;
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::request::Parts;
use axum::routing::{patch, post};
use serde::Deserialize;

use super::AppState;
use super::channel_validation::{validate_channel_name, validate_user_limit};
use super::channels::ChannelDto;
use super::error::ApiError;
use super::extract::{Authed, Json, enforce};
use super::messages::parse_uuid;
use crate::hub::Event;
use crate::ids::{ChannelId, UserId};
use crate::permissions::Permissions;
use crate::ratelimit::Class;
use crate::store::{Channel, ChannelPatch};
use crate::voice::VoiceError;

/// Room names are "<display name>'s room"; the name part is cut to fit.
const ROOM_NAME_PREFIX_CHARS: usize = 50;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/channels/{channel_id}/voice/room", post(open_room))
        .route("/channels/{channel_id}/room", patch(update_room))
        .layer(DefaultBodyLimit::max(4 * 1024))
}

/// The caller's room from this lobby: theirs if it already exists, a new one
/// otherwise, so a retry never makes a second.
async fn open_room(
    Authed(ctx): Authed,
    parts: Parts,
    Path(channel_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<ChannelDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let lobby_id = ChannelId(parse_uuid(&channel_id)?);
    let permissions = state
        .store
        .permissions_in_channel(ctx.user_id, lobby_id)
        .await?;
    if !permissions.contains(Permissions::VIEW_CHANNEL.union(Permissions::CONNECT)) {
        return Err(ApiError::Forbidden);
    }
    let lobby = state
        .store
        .channel(lobby_id)
        .await?
        .ok_or(ApiError::NotFound("channel not found"))?;
    if !lobby.room.creates_rooms {
        return Err(ApiError::BadRequest("this channel does not make rooms"));
    }
    if let Some(room) = state.store.voice_room_of(lobby_id, ctx.user_id).await? {
        return Ok(Json(with_restricted(&state, room).await?));
    }
    let display_name = state
        .store
        .user_profile(ctx.user_id)
        .await?
        .map(|u| u.display_name)
        .unwrap_or_else(|| "someone".to_owned());
    let short: String = display_name.chars().take(ROOM_NAME_PREFIX_CHARS).collect();
    let room = state
        .store
        .create_voice_room(&lobby, ctx.user_id, &format!("{short}'s room"))
        .await?;
    let restricted = state.store.channel_restricted(room.id).await?;
    state
        .hub
        .publish(Event::ChannelCreated(Arc::new(room.clone()), restricted));
    Ok(Json(ChannelDto::with_restricted(room, restricted)))
}

#[derive(Deserialize)]
struct UpdateRoomRequest {
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    locked: Option<bool>,
    #[serde(default)]
    user_limit: Option<i64>,
}

/// The owner's settings, also open to anyone with MANAGE_CHANNELS.
async fn update_room(
    Authed(ctx): Authed,
    parts: Parts,
    Path(channel_id): Path<String>,
    State(state): State<AppState>,
    Json(req): Json<UpdateRoomRequest>,
) -> Result<Json<ChannelDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let channel_id = ChannelId(parse_uuid(&channel_id)?);
    let permissions = state
        .store
        .permissions_in_channel(ctx.user_id, channel_id)
        .await?;
    if !permissions.contains(Permissions::VIEW_CHANNEL) {
        return Err(ApiError::NotFound("channel not found"));
    }
    let room = state
        .store
        .channel(channel_id)
        .await?
        .filter(|c| c.room.is_room())
        .ok_or(ApiError::NotFound("room not found"))?;
    if !manages(&state, &room, ctx.user_id).await? {
        return Err(ApiError::Forbidden);
    }
    let name = req.name.as_deref().map(validate_channel_name).transpose()?;
    let user_limit = req.user_limit.map(validate_user_limit).transpose()?;
    if name.is_none() && req.locked.is_none() && user_limit.is_none() {
        return Err(ApiError::BadRequest("nothing to update"));
    }
    let updated = state
        .store
        .update_channel_settings(
            channel_id,
            ChannelPatch {
                name,
                user_limit,
                room_locked: req.locked,
                ..ChannelPatch::default()
            },
        )
        .await?
        .ok_or(ApiError::NotFound("room not found"))?;
    let restricted = state.store.channel_restricted(channel_id).await?;
    state
        .hub
        .publish(Event::ChannelUpdated(Arc::new(updated.clone()), restricted));
    Ok(Json(ChannelDto::with_restricted(updated, restricted)))
}

/// The room's owner, or anyone with MANAGE_CHANNELS.
async fn manages(state: &AppState, channel: &Channel, user: UserId) -> Result<bool, ApiError> {
    if channel.room.owner_id == Some(user) {
        return Ok(true);
    }
    Ok(state
        .store
        .base_permissions(user)
        .await?
        .contains(Permissions::MANAGE_CHANNELS))
}

async fn with_restricted(state: &AppState, channel: Channel) -> Result<ChannelDto, ApiError> {
    let restricted = state.store.channel_restricted(channel.id).await?;
    Ok(ChannelDto::with_restricted(channel, restricted))
}

/// Refuses a voice token when a lock or a user limit says so. Someone
/// already in the call can always rejoin it, and the room's owner and
/// anyone with MANAGE_CHANNELS are never turned away.
pub(crate) async fn check_join(
    state: &AppState,
    channel: &Channel,
    user: UserId,
) -> Result<(), ApiError> {
    let locked = channel.room.is_room() && channel.room.locked;
    if !locked && channel.room.user_limit == 0 {
        return Ok(());
    }
    if manages(state, channel, user).await? {
        return Ok(());
    }
    let present = match state.voice.list_participants(channel.id).await {
        Ok(list) => list,
        // Nothing to count against without an SFU, and nothing to join either.
        Err(VoiceError::Unavailable) => return Ok(()),
        Err(VoiceError::Internal(err)) => return Err(err.into()),
    };
    if present.iter().any(|p| p.user_id == user) {
        return Ok(());
    }
    if locked {
        return Err(ApiError::Conflict("this room is locked"));
    }
    if present.len() as i64 >= channel.room.user_limit {
        return Err(ApiError::Conflict("this call is full"));
    }
    Ok(())
}
