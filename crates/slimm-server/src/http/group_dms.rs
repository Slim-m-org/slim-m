// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Group DM routes (docs/decisions/0095): start a group, add a person, leave,
//! and rename. A group is a DM channel, so messages, calls and sync use the
//! ordinary `/channels/{channelId}/...` routes; the roster is what lives here.

use axum::Router;
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::StatusCode;
use axum::http::request::Parts;
use axum::routing::{patch, post};
use serde::Deserialize;

use super::AppState;
use super::channels::channel_validation::validate_channel_name;
use super::dms::{DmConversationDto, with_nicknames};
use super::error::ApiError;
use super::extract::{Authed, Json, enforce};
use super::messages::parse_uuid;
use crate::hub::Event;
use crate::ids::{ChannelId, UserId};
use crate::ratelimit::Class;
use crate::store::{GroupDmError, LeftGroup, MemberGate};
use crate::voice::VoiceError;

const BODY_LIMIT: usize = 4 * 1024;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/dms/groups", post(create))
        .route("/dms/groups/{channel_id}", patch(rename))
        .route("/dms/groups/{channel_id}/members", post(add_member))
        .route("/dms/groups/{channel_id}/leave", post(leave))
        .layer(DefaultBodyLimit::max(BODY_LIMIT))
}

#[derive(Deserialize)]
struct CreateRequest {
    /// The new channel's UUIDv7, so a retry finds the group it made.
    id: Option<String>,
    user_ids: Vec<String>,
    name: Option<String>,
}

#[derive(Deserialize)]
struct RenameRequest {
    /// `null` or empty goes back to the default name.
    name: Option<String>,
}

#[derive(Deserialize)]
struct AddRequest {
    user_id: String,
}

impl From<GroupDmError> for ApiError {
    fn from(err: GroupDmError) -> Self {
        match err {
            GroupDmError::NotFound => ApiError::NotFound("no such group"),
            GroupDmError::UserNotFound => ApiError::NotFound("user not found"),
            // The same answer whoever blocked whom, so nobody learns another person's blocks.
            GroupDmError::Blocked => ApiError::ForbiddenBecause(
                "a block between two of these people stops them sharing a group",
            ),
            GroupDmError::BadSize => {
                ApiError::BadRequest("a group has 3 to 8 people, you included")
            }
            GroupDmError::Full => ApiError::Conflict("this group already has 8 people"),
            GroupDmError::AlreadyMember => ApiError::Conflict("already in this group"),
            GroupDmError::IdTaken => ApiError::Conflict("that id is already in use"),
            GroupDmError::Internal(e) => e.into(),
        }
    }
}

async fn require_member(state: &AppState, user_id: UserId) -> Result<(), ApiError> {
    // The gate caps what a DM may do, but would still let one be created.
    if state.store.member_gate(user_id).await? != MemberGate::Member {
        return Err(ApiError::ForbiddenBecause("accept the rules first"));
    }
    Ok(())
}

fn optional_name(name: Option<&str>) -> Result<Option<&str>, ApiError> {
    match name.map(str::trim) {
        None | Some("") => Ok(None),
        Some(_) => name.map(validate_channel_name).transpose(),
    }
}

async fn conversation(
    state: &AppState,
    user_id: UserId,
    channel_id: ChannelId,
) -> Result<Json<DmConversationDto>, ApiError> {
    let conversation = state
        .store
        .group_dm_conversation(user_id, channel_id)
        .await?;
    let mut rendered = with_nicknames(state, vec![conversation]).await?;
    Ok(Json(rendered.remove(0)))
}

/// Starts a group DM with 2 to 7 other people.
async fn create(
    Authed(ctx): Authed,
    parts: Parts,
    State(state): State<AppState>,
    Json(req): Json<CreateRequest>,
) -> Result<(StatusCode, Json<DmConversationDto>), ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    require_member(&state, ctx.user_id).await?;
    let name = optional_name(req.name.as_deref())?;
    let id = req
        .id
        .as_deref()
        .map(|id| parse_uuid(id).map(ChannelId))
        .transpose()?;
    // Bounded before parsing so a huge list cannot cost more than the body limit already allows.
    if req.user_ids.len() > crate::store::GROUP_DM_MAX_PARTICIPANTS {
        return Err(GroupDmError::BadSize.into());
    }
    let others = req
        .user_ids
        .iter()
        .map(|id| parse_uuid(id).map(UserId))
        .collect::<Result<Vec<_>, _>>()?;

    let (channel, created) = state
        .store
        .create_group_dm(ctx.user_id, &others, name, id)
        .await?;
    if created {
        state.hub.publish(Event::DmChanged {
            channel_id: channel.id,
        });
    }
    let status = if created {
        StatusCode::CREATED
    } else {
        StatusCode::OK
    };
    Ok((status, conversation(&state, ctx.user_id, channel.id).await?))
}

/// Adds one person to a group the caller is in.
async fn add_member(
    Authed(ctx): Authed,
    parts: Parts,
    Path(channel_id): Path<String>,
    State(state): State<AppState>,
    Json(req): Json<AddRequest>,
) -> Result<Json<DmConversationDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    require_member(&state, ctx.user_id).await?;
    let channel_id = ChannelId(parse_uuid(&channel_id)?);
    let new_member = UserId(parse_uuid(&req.user_id)?);
    state
        .store
        .add_group_dm_member(ctx.user_id, channel_id, new_member)
        .await?;
    state.hub.publish(Event::DmChanged { channel_id });
    conversation(&state, ctx.user_id, channel_id).await
}

/// Sets or clears the group's custom name; any participant may.
async fn rename(
    Authed(ctx): Authed,
    parts: Parts,
    Path(channel_id): Path<String>,
    State(state): State<AppState>,
    Json(req): Json<RenameRequest>,
) -> Result<Json<DmConversationDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let channel_id = ChannelId(parse_uuid(&channel_id)?);
    let name = optional_name(req.name.as_deref())?;
    state
        .store
        .rename_group_dm(ctx.user_id, channel_id, name)
        .await?;
    state.hub.publish(Event::DmChanged { channel_id });
    conversation(&state, ctx.user_id, channel_id).await
}

/// Leaves a group. The rest keep it and its history; the last one out deletes it.
async fn leave(
    Authed(ctx): Authed,
    parts: Parts,
    Path(channel_id): Path<String>,
    State(state): State<AppState>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let channel_id = ChannelId(parse_uuid(&channel_id)?);
    let outcome = state.store.leave_group_dm(ctx.user_id, channel_id).await?;
    // Best effort: the roster change has committed, so a leaver must not stay on the call.
    match state
        .voice
        .remove_participant(channel_id, ctx.user_id)
        .await
    {
        Ok(()) | Err(VoiceError::Unavailable) => {}
        Err(VoiceError::Internal(err)) => {
            tracing::warn!(%err, %channel_id, "could not remove a leaver from a group call");
        }
    }
    if outcome == LeftGroup::Remains {
        state.hub.publish(Event::DmChanged { channel_id });
    }
    Ok(StatusCode::NO_CONTENT)
}
