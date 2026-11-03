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
use super::extract::{Authed, Json, enforce, require_manage_server};
use super::messages::parse_uuid;
use super::module_host::call_audio_approved;
use crate::call_audio::runtime;
use crate::call_audio::session::EndReason;
use crate::ids::ChannelId;
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
    Ok(Json(current(&state, &id).await?))
}

async fn current(state: &AppState, module_id: &str) -> Result<ChannelList, ApiError> {
    let mut ids: Vec<String> = state
        .store
        .module_call_audio_channels(module_id)
        .await?
        .iter()
        .map(ToString::to_string)
        .collect();
    ids.sort();
    Ok(ChannelList { channel_ids: ids })
}

async fn replace(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    Path(id): Path<String>,
    Json(req): Json<ChannelList>,
) -> Result<Json<ChannelList>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
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
            check_channel(&state, bot, *channel).await?;
        }
    }
    let dropped = state
        .store
        .set_module_call_audio_channels(&id, &wanted)
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
    Ok(Json(current(&state, &id).await?))
}

async fn check_channel(
    state: &AppState,
    bot: crate::ids::UserId,
    channel: ChannelId,
) -> Result<(), ApiError> {
    let found = state.store.channel(channel).await?;
    if !found.is_some_and(|c| c.kind == "voice" && c.parent_message_id.is_none()) {
        return Err(ApiError::BadRequest("channel_ids must be voice channels"));
    }
    if !state
        .store
        .has_permission(bot, channel, Permissions::VIEW_CHANNEL)
        .await?
    {
        return Err(ApiError::BadRequest(
            "the module cannot view one of those channels",
        ));
    }
    Ok(())
}
