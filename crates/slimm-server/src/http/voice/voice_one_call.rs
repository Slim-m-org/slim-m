// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A member is on one call: a join the SFU reports ends their older call in any other room.
//! The SFU replaces a connection only within one room, so a second device joining another channel left the first one live.

use std::collections::HashSet;

use axum::http::StatusCode;

use super::super::AppState;
use super::super::error::ApiError;
use crate::hub::{Event, VoiceRemovalReason};
use crate::ids::{ChannelId, DeviceId, UserId};
use crate::voice::{RoomParticipant, VoiceDevice, VoiceError};

/// The `code` of a comeback refused because the member's call is somewhere else by now.
const ELSEWHERE_CODE: &str = "on_call_elsewhere";

/// Settles the member's other calls after a join into `joined` at `joined_at_ms`.
///
/// The call the member last asked a token for is the one kept. A join into it ends every call
/// the SFU lists as older, so a join reported late, after the member is already back in another
/// room, ends nothing. A join into any other room is a device walking back in on a token the SFU
/// renewed, and is itself removed. With no token on record, after a restart, nothing is ended.
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
    let asked = state.voice.asked_calls().last(user_id);
    for channel_id in elsewhere {
        if !joined_before(state, user_id, channel_id, joined_at_ms).await {
            continue;
        }
        match asked {
            Some(asked) if asked == joined => end_call(state, user_id, channel_id).await,
            Some(_) => return end_call(state, user_id, joined).await,
            None => tracing::info!(
                %user_id,
                %channel_id,
                "left a member on two calls: no token on record says which they chose"
            ),
        }
    }
}

/// Refuses a rejoin the client makes by itself when the member's call is elsewhere by now: in
/// another channel, or in this one on another of their devices. A person's own join is never
/// asked this, since that one moves the call.
pub(in crate::http) async fn check_comeback(
    state: &AppState,
    user_id: UserId,
    channel_id: ChannelId,
    device: &VoiceDevice,
) -> Result<(), ApiError> {
    if state.store.is_bot(user_id).await? {
        return Ok(());
    }
    let moved_on = !calls_elsewhere(state, user_id, channel_id).is_empty()
        || held_by_another_device(state, user_id, channel_id, device).await;
    if moved_on {
        return Err(ApiError::Coded {
            status: StatusCode::CONFLICT,
            message: "this account is on a call on another device",
            code: ELSEWHERE_CODE,
        });
    }
    Ok(())
}

/// An SFU that cannot be read answers no: a comeback is what a failing network produces.
async fn held_by_another_device(
    state: &AppState,
    user_id: UserId,
    channel_id: ChannelId,
    device: &VoiceDevice,
) -> bool {
    let Ok(listed) = state.voice.list_participants(channel_id).await else {
        return false;
    };
    let tag = state.voice.device_tag(channel_id, device.clone());
    listed
        .iter()
        .filter(|p| p.user_id == user_id)
        .any(|p| p.device_id.is_some() && !is_device(p, tag.as_deref(), device.device_id))
}

/// Whether `participant` is the connection of the device asking. A token minted before device
/// tags carried the raw id, and its call can outlive a deploy.
pub(in crate::http) fn is_device(
    participant: &RoomParticipant,
    tag: Option<&str>,
    device_id: DeviceId,
) -> bool {
    participant
        .device_id
        .as_deref()
        .is_some_and(|shown| Some(shown) == tag || shown == device_id.to_string())
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
        Ok(()) => {
            tracing::info!(
                %user_id,
                %channel_id,
                "ended a member's older call after they joined another"
            );
            state.hub.publish(Event::VoiceRemoved {
                user_id,
                channel_id,
                reason: VoiceRemovalReason::OtherDevice,
            });
        }
        Err(VoiceError::Unavailable) => {}
        Err(VoiceError::Internal(err)) => {
            tracing::warn!(%err, %channel_id, "could not end a member's older call");
        }
    }
}
