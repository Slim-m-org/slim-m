// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Background sweeps for voice calls, rooms, and rings.

use futures_util::StreamExt;

use super::spawn_sweep;
use crate::store::Store;
use crate::{hub, store, voice};

/// How often stale voice calls are swept from the in-memory activity map.
const CALL_SWEEP_INTERVAL: std::time::Duration = std::time::Duration::from_secs(10);

/// Runs the stale-voice-call sweep in the background; see [`spawn_sweep`].
///
/// A deployment with no SFU configured never has anything to sweep, so this is
/// safe to spawn unconditionally.
pub(crate) fn spawn_call_sweep(store: store::Store, voice: voice::VoiceService, hub: hub::Hub) {
    spawn_sweep(CALL_SWEEP_INTERVAL, move || {
        let store = store.clone();
        let voice = voice.clone();
        let hub = hub.clone();
        async move {
            let stale = sweep_stale_voice_calls(&voice, &hub).await;
            crate::voice_session_sweeps::close_stale_sessions(&store, &hub, &stale).await;
        }
    });
}

/// How often call history past its retention is deleted (decision 0066).
const CALL_HISTORY_SWEEP_INTERVAL: std::time::Duration = std::time::Duration::from_secs(60 * 60);

/// Runs the call history retention sweep in the background; see [`spawn_sweep`].
pub(crate) fn spawn_call_history_sweep(store: store::Store) {
    spawn_sweep(CALL_HISTORY_SWEEP_INTERVAL, move || {
        let store = store.clone();
        async move {
            if let Err(err) = store.sweep_voice_events().await {
                tracing::warn!(%err, "could not sweep old call history");
            }
        }
    });
}

/// How often emptied temporary voice rooms are looked for; the webhook
/// usually removes them first, so this only catches a missed one.
const ROOM_SWEEP_INTERVAL: std::time::Duration = std::time::Duration::from_secs(60);

/// Runs the empty-room sweep in the background; see [`spawn_sweep`].
pub(crate) fn spawn_room_sweep(store: store::Store, voice: voice::VoiceService, hub: hub::Hub) {
    spawn_sweep(ROOM_SWEEP_INTERVAL, move || {
        let (store, voice, hub) = (store.clone(), voice.clone(), hub.clone());
        async move {
            crate::room_cleanup::sweep_empty_rooms(&store, &voice, &hub).await;
        }
    });
}

/// One pass of the stale-call sweep, evicting every call whose heartbeat has
/// gone stale as of now.
pub async fn sweep_stale_voice_calls(
    voice: &voice::VoiceService,
    hub: &hub::Hub,
) -> Vec<(crate::ids::UserId, crate::ids::ChannelId)> {
    sweep_stale_voice_calls_at(voice, hub, std::time::Instant::now()).await
}

/// [`sweep_stale_voice_calls`] with an explicit clock.
///
/// Split out of [`spawn_call_sweep`]'s loop, and `pub` rather than private,
/// so a test can drive the real coupling between
/// [`voice::VoiceService::sweep_stale_calls_at`] and
/// [`voice::VoiceService::remove_participant`] against a controlled clock,
/// rather than re-implementing the loop and risking the copy drifting from
/// what actually runs.
///
/// Publishes [`hub::Event::VoiceActivityChanged`] for every evicted
/// `(user, channel)` pair regardless of whether the best-effort SFU removal
/// below it succeeds: the heartbeat going stale is already the real
/// transition, committed by [`voice::VoiceService::sweep_stale_calls_at`]
/// before this ever runs, so bystanders are told up front rather than behind
/// the removal round trips.
///
/// The removals themselves fan out with bounded concurrency. Each is a real
/// HTTP POST to LiveKit, so a blip that expires many heartbeats in one tick
/// would otherwise serialise N round trips end to end; [`STALE_SWEEP_CONCURRENCY`]
/// collapses that burst without opening an unbounded number of connections at
/// once (SRV6).
pub async fn sweep_stale_voice_calls_at(
    voice: &voice::VoiceService,
    hub: &hub::Hub,
    now: std::time::Instant,
) -> Vec<(crate::ids::UserId, crate::ids::ChannelId)> {
    let stale = voice.sweep_stale_calls_at(now);
    for (_, channel_id) in &stale {
        hub.publish(hub::Event::VoiceActivityChanged {
            channel_id: *channel_id,
        });
    }
    futures_util::stream::iter(stale.clone())
        .for_each_concurrent(
            STALE_SWEEP_CONCURRENCY,
            |(user_id, channel_id)| async move {
                match voice.remove_participant(channel_id, user_id).await {
                    Ok(()) => tracing::info!(
                        %user_id,
                        %channel_id,
                        "removed a voice participant with no recent heartbeat"
                    ),
                    Err(voice::VoiceError::Unavailable) => {}
                    Err(voice::VoiceError::Internal(err)) => tracing::warn!(
                        error = %err,
                        %user_id,
                        %channel_id,
                        "failed to remove a stale voice participant"
                    ),
                }
            },
        )
        .await;
    stale
}

/// How many stale-participant removals the sweep runs at once. A burst that
/// expires many heartbeats in one tick is rare, so this only has to keep that
/// burst from serialising while staying well under a thundering herd of
/// simultaneous connections to the SFU.
const STALE_SWEEP_CONCURRENCY: usize = 16;

/// How often an outstanding DM call ring is checked for having gone past
/// [`voice::RING_TIMEOUT`]. Short, the same reasoning [`CALL_SWEEP_INTERVAL`]
/// gives: this bounds how long a caller can sit alone on an open SFU room
/// after nobody answered, so the interval is part of that bound rather than
/// housekeeping on its own schedule.
const RING_SWEEP_INTERVAL: std::time::Duration = std::time::Duration::from_secs(2);

/// Runs the stale-call-ring sweep in the background; see [`spawn_sweep`].
///
/// A deployment with no SFU configured, or one that never rings, never has
/// anything to sweep, so this is safe to spawn unconditionally.
pub(crate) fn spawn_ring_sweep(
    voice: voice::VoiceService,
    hub: hub::Hub,
    store: Store,
    push: crate::push::PushSender,
) {
    spawn_sweep(RING_SWEEP_INTERVAL, move || {
        let voice = voice.clone();
        let hub = hub.clone();
        let store = store.clone();
        let push = push.clone();
        async move {
            sweep_stale_call_rings(&voice, &hub, &store, &push).await;
        }
    });
}

/// One pass of the stale-call-ring sweep: every ring nobody answered inside
/// [`voice::RING_TIMEOUT`] is ended, and the caller's own SFU participant -
/// left dangling in a room they may well have joined alone while it rang -
/// is released.
///
/// A distinct sweep from [`sweep_stale_voice_calls`] rather than folded into
/// it: a heartbeat going stale means a participant's own connection went
/// quiet, which says nothing about whether anybody else ever joined them.
/// This one instead asks "did a call that was never joined by a second
/// person ever get answered", the condition the owner actually flagged as
/// wasting resources - a caller sitting alone with a perfectly live
/// heartbeat is exactly the case [`sweep_stale_voice_calls`] cannot see.
pub async fn sweep_stale_call_rings(
    voice: &voice::VoiceService,
    hub: &hub::Hub,
    store: &Store,
    push: &crate::push::PushSender,
) {
    sweep_stale_call_rings_at(voice, hub, store, push, std::time::Instant::now()).await;
}

/// [`sweep_stale_call_rings`] with an explicit clock, `pub` for the same
/// testing reason [`sweep_stale_voice_calls_at`] is.
pub async fn sweep_stale_call_rings_at(
    voice: &voice::VoiceService,
    hub: &hub::Hub,
    store: &Store,
    push: &crate::push::PushSender,
    now: std::time::Instant,
) {
    for (channel_id, ring_id, caller_id) in voice.rings().sweep_stale_at(now) {
        hub.publish(hub::Event::CallRingEnded {
            channel_id,
            ring_id,
            outcome: voice::CallRingOutcome::TimedOut,
        });
        // The missed call: the one outcome that used to leave no trace.
        voice::record_finished_call(
            store,
            hub,
            push,
            channel_id,
            ring_id,
            caller_id,
            voice::CallRingOutcome::TimedOut,
        )
        .await;
        match voice.remove_participant(channel_id, caller_id).await {
            Ok(()) => tracing::info!(
                %channel_id,
                %caller_id,
                "released a dm call room nobody answered before the ring timed out"
            ),
            Err(voice::VoiceError::Unavailable) => {}
            Err(voice::VoiceError::Internal(err)) => tracing::warn!(
                error = %err,
                %channel_id,
                "failed to release an unanswered dm call room"
            ),
        }
    }
}
