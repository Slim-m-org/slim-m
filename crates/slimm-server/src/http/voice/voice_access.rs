// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Ends a call for whoever a role, member-role or overwrite change just took View or Connect from.
//! A LiveKit token cannot be revoked, so without this they stay in the room until the heartbeat sweep.

use futures_util::StreamExt;
use futures_util::stream;
use tokio::sync::broadcast::Receiver;
use tokio::sync::broadcast::error::{RecvError, TryRecvError};
use tokio::task::JoinHandle;

use super::super::AppState;
use crate::hub::{Event, moves_permissions};
use crate::ids::{ChannelId, UserId};
use crate::permissions::Permissions;
use crate::voice::VoiceError;

/// What being on a channel's call needs, the same pair the heartbeat and the token require.
const IN_CALL: Permissions = Permissions::VIEW_CHANNEL.union(Permissions::CONNECT);

/// How many evictions run at once after one change.
const EVICT_CONCURRENCY: usize = 8;

/// Subscribes before the task starts, so a change published after this call is never missed.
pub fn spawn_voice_access_watch(state: AppState) -> JoinHandle<()> {
    let events = state.hub.subscribe();
    tokio::spawn(watch(state, events))
}

async fn watch(state: AppState, mut events: Receiver<Event>) {
    loop {
        let relevant = match events.recv().await {
            Ok(event) => moves_permissions(&event),
            // A missed event may have been a revoke, so a lag re-checks everyone too.
            Err(RecvError::Lagged(_)) => true,
            Err(RecvError::Closed) => return,
        };
        if !relevant {
            continue;
        }
        // A burst (a reorder, a bulk role change) is answered by one pass.
        loop {
            match events.try_recv() {
                Ok(_) | Err(TryRecvError::Lagged(_)) => {}
                Err(TryRecvError::Empty) => break,
                Err(TryRecvError::Closed) => return,
            }
        }
        evict_who_lost_access(&state).await;
    }
}

/// Removes from the SFU everyone on a call who no longer holds View and Connect in its channel.
pub async fn evict_who_lost_access(state: &AppState) {
    let mut lost = Vec::new();
    for (user_id, channel_id) in state.voice.calls() {
        match state
            .store
            .permissions_in_channel(user_id, channel_id)
            .await
        {
            Ok(held) if held.contains(IN_CALL) => {}
            Ok(_) => lost.push((user_id, channel_id)),
            Err(err) => tracing::warn!(%err, "could not re-check a voice participant's access"),
        }
    }
    stream::iter(lost)
        .for_each_concurrent(EVICT_CONCURRENCY, |(user_id, channel_id)| {
            evict(state, user_id, channel_id)
        })
        .await;
}

/// Drops one call whose access is gone; a call already ended some other way is left alone.
async fn evict(state: &AppState, user_id: UserId, channel_id: ChannelId) {
    if forget_call(state, user_id, channel_id) {
        remove_from_room(state, user_id, channel_id).await;
    }
}

/// Drops the call of someone whose own heartbeat was just refused for lost access.
///
/// The heartbeat is the proof they are in the room, so they are removed even
/// when no earlier heartbeat was on record for a pass to have found.
pub(in crate::http) async fn evict_refused_heartbeat(
    state: &AppState,
    user_id: UserId,
    channel_id: ChannelId,
) {
    forget_call(state, user_id, channel_id);
    remove_from_room(state, user_id, channel_id).await;
}

/// Removes someone the SFU just let in who holds no View and Connect in the channel.
///
/// The SFU renews every token it accepts, so one minted before the access went
/// still joins; this is the check a join by that token never otherwise meets.
pub(in crate::http) async fn evict_join_without_access(
    state: &AppState,
    user_id: UserId,
    channel_id: ChannelId,
) {
    match state
        .store
        .permissions_in_channel(user_id, channel_id)
        .await
    {
        Ok(held) if held.contains(IN_CALL) => {}
        Ok(_) => evict_refused_heartbeat(state, user_id, channel_id).await,
        Err(err) => {
            tracing::warn!(%err, "could not check a voice participant's access as they joined")
        }
    }
}

/// Forgets the call's heartbeat, telling the channel when there was one.
fn forget_call(state: &AppState, user_id: UserId, channel_id: ChannelId) -> bool {
    let forgotten = state
        .voice
        .forget_heartbeat_reporting_removed(user_id, channel_id);
    if forgotten {
        state
            .hub
            .publish(Event::VoiceActivityChanged { channel_id });
    }
    forgotten
}

async fn remove_from_room(state: &AppState, user_id: UserId, channel_id: ChannelId) {
    match state.voice.remove_participant(channel_id, user_id).await {
        Ok(()) => {
            tracing::info!(%user_id, %channel_id, "removed a voice participant who lost access")
        }
        Err(VoiceError::Unavailable) => {}
        Err(VoiceError::Internal(err)) => {
            tracing::warn!(%err, "could not remove a voice participant who lost access");
        }
    }
}
