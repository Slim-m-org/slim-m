// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The voice channels an admin lets a module hear (decision 0105). The list
//! starts empty, never holds a direct message call, and every change is audited.

use axum::Router;
use axum::extract::{Path, State};
use axum::http::request::Parts;
use axum::routing::get;
use serde::{Deserialize, Serialize};

use super::AppState;
use super::error::ApiError;
use super::extract::{Authed, AuthedLimited, Json, WRITE, enforce, require_manage_server};
use super::messages::parse_uuid;
use super::module_host::call_audio_approved;
use crate::call_audio::runtime;
use crate::call_audio::session::EndReason;
use crate::ids::{ChannelId, UserId};
use crate::permissions::Permissions;
use crate::ratelimit::Class;
use crate::store::now_ms;

/// Most voice channels one module can be armed for.
const MAX_CHANNELS: usize = 50;

pub fn routes() -> Router<AppState> {
    Router::new().route(
        "/space/dock/modules/{id}/call-audio-channels",
        get(list).put(replace),
    )
}

#[derive(Serialize, Deserialize)]
struct ChannelList {
    channel_ids: Vec<String>,
}

async fn list(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    Path(id): Path<String>,
) -> Result<Json<ChannelList>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::AuthedRead)?;
    require_manage_server(&state, ctx.user_id).await?;
    state
        .store
        .installed_module(&id)
        .await?
        .ok_or(ApiError::NotFound("module not installed"))?;
    let armed = state.store.module_call_audio_channels(&id).await?;
    let (seen, _) = split_by_sight(&state, ctx.user_id, armed).await?;
    Ok(Json(ChannelList::of(seen)))
}

impl ChannelList {
    fn of(mut channels: Vec<ChannelId>) -> Self {
        channels.sort_by_key(ToString::to_string);
        let channel_ids = channels.iter().map(ToString::to_string).collect();
        Self { channel_ids }
    }
}

/// `channels` as those `caller` can see and those they cannot. A manager's list is the first
/// half only: what they cannot see they are neither shown nor able to arm or disarm.
async fn split_by_sight(
    state: &AppState,
    caller: UserId,
    channels: Vec<ChannelId>,
) -> Result<(Vec<ChannelId>, Vec<ChannelId>), ApiError> {
    // An administrator's list is the whole list, a since-deleted channel included.
    if (state.store.base_permissions(caller).await?).contains(Permissions::ADMINISTRATOR) {
        return Ok((channels, Vec::new()));
    }
    let held = state
        .store
        .permissions_in_channels(caller, &channels)
        .await?;
    let sees = |channel: &ChannelId| {
        held.get(channel)
            .is_some_and(|p| p.contains(Permissions::VIEW_CHANNEL))
    };
    Ok(channels.into_iter().partition(sees))
}

async fn replace(
    State(state): State<AppState>,
    AuthedLimited(ctx): AuthedLimited<WRITE>,
    Path(id): Path<String>,
    Json(req): Json<ChannelList>,
) -> Result<Json<ChannelList>, ApiError> {
    require_manage_server(&state, ctx.user_id).await?;
    let module = state
        .store
        .installed_module(&id)
        .await?
        .ok_or(ApiError::NotFound("module not installed"))?;
    let mut wanted: Vec<ChannelId> = Vec::new();
    for raw in &req.channel_ids {
        let channel = ChannelId(parse_uuid(raw)?);
        if !wanted.contains(&channel) {
            wanted.push(channel);
        }
    }
    if wanted.len() > MAX_CHANNELS {
        return Err(ApiError::BadRequest("too many channels"));
    }
    if !wanted.is_empty() {
        if !call_audio_approved(&module) {
            return Err(ApiError::Conflict(
                "the module's call audio is not approved",
            ));
        }
        let bot = module
            .bot_user_id
            .ok_or(ApiError::Conflict("the module has no principal"))?;
        for channel in &wanted {
            check_channel(&state, (ctx.user_id, bot), *channel).await?;
        }
    }
    // What the caller cannot see stays armed as it was: their list never named it.
    let armed = state.store.module_call_audio_channels(&id).await?;
    let (_, unseen) = split_by_sight(&state, ctx.user_id, armed).await?;
    let kept: Vec<ChannelId> = wanted.iter().chain(&unseen).copied().collect();
    let dropped = state
        .store
        .set_module_call_audio_channels(&id, &kept)
        .await?;
    for channel in dropped {
        let session = state.call_audio.view(channel);
        if session.is_some_and(|v| v.module_id == id)
            && let Some(outcome) =
                state
                    .call_audio
                    .end(channel, EndReason::ChannelRemoved, now_ms())
        {
            runtime::apply(&state, outcome).await;
        }
    }
    Ok(Json(ChannelList::of(wanted)))
}

/// A voice channel both the caller and the module can see. One the caller cannot see answers
/// exactly like one that is not a voice channel at all.
async fn check_channel(
    state: &AppState,
    (caller, bot): (UserId, UserId),
    channel: ChannelId,
) -> Result<(), ApiError> {
    let found = state.store.channel(channel).await?;
    let is_voice = found.is_some_and(|c| c.kind == "voice" && c.parent_message_id.is_none());
    let view = Permissions::VIEW_CHANNEL;
    if !is_voice || !state.store.has_permission(caller, channel, view).await? {
        return Err(ApiError::BadRequest("channel_ids must be voice channels"));
    }
    if !state.store.has_permission(bot, channel, view).await? {
        return Err(ApiError::BadRequest(
            "the module cannot view one of those channels",
        ));
    }
    Ok(())
}
