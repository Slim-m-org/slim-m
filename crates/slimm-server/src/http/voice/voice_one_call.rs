// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A member is on one call: a join the SFU reports ends their older call in any other room.
//! The SFU replaces a connection only within one room, so a second device joining another channel left the first one live.

use std::collections::HashSet;

use super::super::AppState;
use crate::hub::Event;
use crate::ids::{ChannelId, UserId};
use crate::voice::VoiceError;

/// Ends every call `user_id` joined before `joined_at_ms`, other than the one in `joined`.
///
/// Only a connection the SFU itself lists as older is removed, so a join reported late,
/// after the member is already back in another room, ends nothing.
pub(super) async fn end_older_calls(
    state: &AppState,
    user_id: UserId,
    joined: ChannelId,
    joined_at_ms: Option<i64>,
) {
    let Some(joined_at_ms) = joined_at_ms else {
        return;
    };
    let elsewhere = calls_elsewhere(state, user_id, joined);
    // A bot is a program, and one may serve several calls at once.
    if elsewhere.is_empty() || state.store.is_bot(user_id).await.unwrap_or(true) {
        return;
    }
    for channel_id in elsewhere {
        if joined_before(state, user_id, channel_id, joined_at_ms).await {
            end_call(state, user_id, channel_id).await;
        }
    }
}

/// The other channels the member is on a call in, by heartbeat or by the SFU's own word.
fn calls_elsewhere(state: &AppState, user_id: UserId, joined: ChannelId) -> HashSet<ChannelId> {
    let by_heartbeat = state
        .voice
        .calls()
        .into_iter()
        .filter(|(user, _)| *user == user_id)
        .map(|(_, channel)| channel);
    let by_webhook = state.voice.live_state().channels_of(user_id);
    by_heartbeat
        .chain(by_webhook)
        .filter(|channel| *channel != joined)
        .collect()
}

async fn joined_before(
    state: &AppState,
    user_id: UserId,
    channel_id: ChannelId,
    joined_at_ms: i64,
) -> bool {
    match state.voice.list_participants(channel_id).await {
        Ok(listed) => listed
            .iter()
            .filter(|p| p.user_id == user_id)
            .any(|p| p.joined_at_ms.is_some_and(|theirs| theirs < joined_at_ms)),
        Err(VoiceError::Unavailable) => false,
        Err(VoiceError::Internal(err)) => {
            tracing::warn!(%err, %channel_id, "could not check a member's other call as they joined a new one");
            false
        }
    }
}

async fn end_call(state: &AppState, user_id: UserId, channel_id: ChannelId) {
    if state
        .voice
        .forget_heartbeat_reporting_removed(user_id, channel_id)
    {
        state
            .hub
            .publish(Event::VoiceActivityChanged { channel_id });
    }
    match state.voice.remove_participant(channel_id, user_id).await {
        Ok(()) => tracing::info!(
            %user_id,
            %channel_id,
            "ended a member's older call after they joined another"
        ),
        Err(VoiceError::Unavailable) => {}
        Err(VoiceError::Internal(err)) => {
            tracing::warn!(%err, %channel_id, "could not end a member's older call");
        }
    }
}
