// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Ends a call for whoever a role, member-role or overwrite change just took View or Connect from,
//! and for a device whose sessions were all revoked.
//! A LiveKit token cannot be revoked, so without this they stay in the room until the heartbeat sweep.

use futures_util::StreamExt;
use futures_util::stream;
use tokio::sync::broadcast::Receiver;
use tokio::sync::broadcast::error::{RecvError, TryRecvError};
use tokio::task::JoinHandle;

use super::super::AppState;
use crate::hub::{Event, moves_permissions};
use crate::ids::{ChannelId, DeviceId, UserId};
use crate::permissions::Permissions;
use crate::voice::{RoomParticipant, VoiceError};

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

/// Removes someone the SFU just let in who holds no View and Connect in the channel, or whose
/// token's device is signed out, answering whether they stay.
///
/// The SFU renews every token it accepts, so one minted before the access or the session went
/// still joins; this is the check a join by that token never otherwise meets.
pub(in crate::http) async fn evict_join_without_access(
    state: &AppState,
    user_id: UserId,
    channel_id: ChannelId,
    holder: Option<&str>,
) -> bool {
    let stays = match state
        .store
        .permissions_in_channel(user_id, channel_id)
        .await
    {
        Ok(held) if held.contains(IN_CALL) => match state.store.live_device_ids(user_id).await {
            Ok(live) => held_by_live_device(state, channel_id, holder, &live),
            Err(err) => {
                tracing::warn!(%err, "could not check a voice participant's sessions as they joined");
                true
            }
        },
        Ok(_) => false,
        Err(err) => {
            tracing::warn!(%err, "could not check a voice participant's access as they joined");
            true
        }
    };
    if !stays {
        evict_refused_heartbeat(state, user_id, channel_id).await;
    }
    stays
}

/// Ends each call of `user_id`'s that a device with no live session left joined.
pub(in crate::http) async fn evict_calls_without_live_device(state: &AppState, user_id: UserId) {
    let mut channels = state.voice.live_state().channels_of(user_id);
    channels.extend(
        state
            .voice
            .calls()
            .into_iter()
            .filter(|(user, _)| *user == user_id)
            .map(|(_, channel)| channel),
    );
    channels.sort_unstable_by_key(|channel| channel.0);
    channels.dedup();
    if channels.is_empty() {
        return;
    }
    let live = match state.store.live_device_ids(user_id).await {
        Ok(live) => live,
        Err(err) => {
            tracing::warn!(%err, "could not read which devices are still signed in");
            return;
        }
    };
    for channel_id in channels {
        let listed = match state.voice.list_participants(channel_id).await {
            Ok(listed) => listed,
            Err(VoiceError::Unavailable) => return,
            Err(VoiceError::Internal(err)) => {
                tracing::warn!(%err, %channel_id, "could not list a call to end a signed-out device's place in it");
                continue;
            }
        };
        let signed_out = |p: &RoomParticipant| {
            p.user_id == user_id
                && !held_by_live_device(state, channel_id, p.holder.as_deref(), &live)
        };
        if listed.iter().any(signed_out) {
            evict_refused_heartbeat(state, user_id, channel_id).await;
        }
    }
}

/// Whether the token a participant joined with was minted on a device that still holds a session.
fn held_by_live_device(
    state: &AppState,
    channel_id: ChannelId,
    holder: Option<&str>,
    live: &[DeviceId],
) -> bool {
    match holder {
        Some(holder) => live
            .iter()
            .any(|device| state.voice.holder_tag(channel_id, *device).as_deref() == Some(holder)),
        // A token from before holder tags names no device, so only a wholly signed-out account is refused.
        None => !live.is_empty(),
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
