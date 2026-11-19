// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What a caller tells the call about their own microphone and hearing, so the people in it and
//! everyone watching the channel from outside it see the right icons.

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::http::request::Parts;
use serde::Deserialize;

use super::super::AppState;
use super::super::error::ApiError;
use super::super::extract::{Authed, Json, enforce};
use super::super::messages::parse_uuid;
use crate::hub::Event;
use crate::ids::ChannelId;
use crate::permissions::Permissions;
use crate::ratelimit::Class;
use crate::store::SessionContext;
use crate::voice::VoiceError;

const NO_VOICE: &str = "this server has no voice configured";

#[derive(Deserialize)]
pub(super) struct DeafenedRequest {
    deafened: bool,
}

#[derive(Deserialize)]
pub(super) struct MutedRequest {
    muted: bool,
}

/// Tells the room whether the caller has deafened themselves. Idempotent, and
/// a no-op when the caller is not in the room, since the SFU is the authority
/// on who is connected.
pub(super) async fn set_deafened(
    Authed(ctx): Authed,
    parts: Parts,
    Path(channel_id): Path<String>,
    State(state): State<AppState>,
    Json(body): Json<DeafenedRequest>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let channel_id = ChannelId(parse_uuid(&channel_id)?);
    may_report(&state, &ctx, channel_id).await?;

    match state
        .voice
        .set_participant_deafened(channel_id, ctx.user_id, body.deafened)
        .await
    {
        Ok(()) => {
            nudge_roster(&state, &ctx, channel_id);
            Ok(StatusCode::NO_CONTENT)
        }
        Err(VoiceError::Unavailable) => Err(ApiError::NotConfigured(NO_VOICE)),
        Err(VoiceError::Internal(err)) => {
            tracing::warn!(%err, "could not publish a participant's deafened state");
            Err(ApiError::Unavailable)
        }
    }
}

/// Tells everyone watching the channel that the caller muted or unmuted. The SFU already carries
/// the mute on the caller's own track, which the roster reads; this only says to read it again.
pub(super) async fn set_muted(
    Authed(ctx): Authed,
    parts: Parts,
    Path(channel_id): Path<String>,
    State(state): State<AppState>,
    Json(body): Json<MutedRequest>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let channel_id = ChannelId(parse_uuid(&channel_id)?);
    if !state.voice.is_enabled() {
        return Err(ApiError::NotConfigured(NO_VOICE));
    }
    may_report(&state, &ctx, channel_id).await?;
    tracing::debug!(user_id = %ctx.user_id, %channel_id, muted = body.muted, "a caller changed their mute");
    nudge_roster(&state, &ctx, channel_id);
    Ok(StatusCode::NO_CONTENT)
}

/// The gate both reports share: `VIEW_CHANNEL` and `CONNECT` on a channel that can host a call.
async fn may_report(
    state: &AppState,
    ctx: &SessionContext,
    channel_id: ChannelId,
) -> Result<(), ApiError> {
    let permissions = state
        .store
        .permissions_in_channel(ctx.user_id, channel_id)
        .await?;
    if !permissions.contains(Permissions::VIEW_CHANNEL.union(Permissions::CONNECT)) {
        return Err(ApiError::Forbidden);
    }
    super::callable_channel(state, channel_id).await?;
    Ok(())
}

/// Has every roster of the channel re-read, so a viewer outside the call sees the new icon.
/// Only for a caller with a call on record there, so a bystander cannot make the channel refetch.
fn nudge_roster(state: &AppState, ctx: &SessionContext, channel_id: ChannelId) {
    if !state.voice.has_heartbeat(ctx.user_id, channel_id) {
        return;
    }
    state.voice.roster_cache().invalidate(channel_id);
    state
        .hub
        .publish(Event::VoiceActivityChanged { channel_id });
}
