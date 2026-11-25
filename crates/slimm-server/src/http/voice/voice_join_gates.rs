// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The gates a voice token meets (a locked room, a module's join hook) for the ways in that do
//! not mint one: a join on a token the SFU renewed, and a first heartbeat.

use super::super::AppState;
use super::super::error::ApiError;
use super::super::module_hooks::{self, Action};
use super::voice_rooms;
use crate::ids::{ChannelId, UserId};
use crate::store::Channel;

/// Whether a join the SFU accepted is turned away. A join inside one token lifetime of a mint
/// already met these gates, and so did a member whose call is on record (a reconnect on a
/// renewed token); anything else came in on a renewed token.
pub(in crate::http) async fn refuses_renewed_join(
    state: &AppState,
    user_id: UserId,
    channel_id: ChannelId,
) -> bool {
    if state
        .voice
        .asked_calls()
        .minted_recently(user_id, channel_id)
    {
        return false;
    }
    if state.voice.has_heartbeat(user_id, channel_id) {
        return false;
    }
    let channel = match state.store.channel(channel_id).await {
        Ok(Some(channel)) => channel,
        Ok(None) => return false,
        Err(err) => {
            tracing::warn!(%err, "could not read a channel to check a voice join against it");
            return false;
        }
    };
    match voice_rooms::locked_against(state, &channel, user_id).await {
        Ok(true) => return true,
        Ok(false) => {}
        Err(_) => return false,
    }
    join_hook(state, user_id, channel_id).await.is_err()
}

/// Holds a first heartbeat to the gates the token has, unless the token was just minted or the
/// SFU has already let the member in, since the token or the join check ran those then.
pub(in crate::http) async fn check_first_heartbeat(
    state: &AppState,
    channel: &Channel,
    user_id: UserId,
) -> Result<(), ApiError> {
    let voice = &state.voice;
    if voice.live_state().is_present(channel.id, user_id)
        || voice.asked_calls().minted_recently(user_id, channel.id)
    {
        return Ok(());
    }
    voice_rooms::check_join(state, channel, user_id).await?;
    join_hook(state, user_id, channel.id).await
}

async fn join_hook(
    state: &AppState,
    user_id: UserId,
    channel_id: ChannelId,
) -> Result<(), ApiError> {
    module_hooks::check_permission(state, user_id, (Action::VoiceJoin, Some(channel_id))).await
}
