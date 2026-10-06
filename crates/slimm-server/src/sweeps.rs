// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The background sweeps [`crate::run`] spawns: expired tokens, orphaned
//! attachments, canvas op compaction, stale voice calls and rings, and
//! message retention. Split out of `lib.rs` to keep that file under the
//! review budget; every sweep here follows the same detached, best-effort,
//! wait-first model [`spawn_token_sweep`] documents once.
//!
//! Every sweep that touches storage records its own run in `sweep_status`
//! via [`record_sweep_run`], best-effort, so `GET /space/storage` can show an
//! operator when each last ran and roughly what it reclaimed.

use futures_util::StreamExt;

use crate::store::Store;
use crate::{hub, media, store, voice};

/// Records that a sweep just ran, for the operator-visible storage view at
/// `GET /space/storage`. Best-effort: a failure here is only ever logged,
/// never allowed to affect the sweep it is called from, since the sweep's
/// own work already committed before this runs.
async fn record_sweep_run(store: &store::Store, name: &str, reclaimed: i64) {
    if let Err(err) = store.record_sweep_run(name, reclaimed).await {
        tracing::warn!(error = %err, sweep = name, "failed to record sweep run status");
    }
}

/// Spawns one background sweep on the model every sweep in this file follows.
///
/// Detached and best-effort: a failed pass is logged where it failed and
/// retried on the next tick, never propagated, because nothing a request does
/// depends on it.
///
/// Wait-first: the leading `tick` waits out the interval rather than firing at
/// startup, so a container that crash-loops does not hammer the same delete on
/// every boot.
///
/// A combinator rather than six copies of the same five lines, because the
/// part worth not getting wrong is the shape and not the bodies. A sweep that
/// forgot the leading `tick` would run on every boot and nothing would say so;
/// written this way it cannot be forgotten. Each caller hands over a closure
/// rather than a future, since the pass runs again on every tick - the handles
/// these capture (`Store`, `Hub`, `VoiceService`, `Media`, `PushSender`) are
/// `Arc` clones, bar `Media`'s two owned `PathBuf`s - and that one is captured
/// only by the hourly and six-hourly sweeps, never the two-second ring.
fn spawn_sweep<F, Fut>(interval: std::time::Duration, pass: F)
where
    F: Fn() -> Fut + Send + 'static,
    Fut: std::future::Future<Output = ()> + Send,
{
    tokio::spawn(async move {
        let mut ticker = tokio::time::interval(interval);
        ticker.tick().await;
        loop {
            ticker.tick().await;
            pass().await;
        }
    });
}

/// How often expired token rows are swept. Long, because nothing depends on
/// the rows going promptly: they are already refused by their own `expires_at`
/// checks, and this only reclaims the space and keeps the indexes over them
/// from growing without bound for the life of a deployment.
const TOKEN_SWEEP_INTERVAL: std::time::Duration = std::time::Duration::from_secs(6 * 60 * 60);

/// Runs the token sweep in the background for the life of the process; see
/// [`spawn_sweep`] for the model all six follow.
pub(crate) fn spawn_token_sweep(store: store::Store) {
    spawn_sweep(TOKEN_SWEEP_INTERVAL, move || {
        let store = store.clone();
        async move {
            // Same schedule and reasoning as the token sweep: a spent challenge grants nothing.
            match store.sweep_expired_totp_challenges().await {
                Ok(0) => {}
                Ok(swept) => tracing::info!(swept, "swept expired TOTP challenge rows"),
                Err(err) => tracing::warn!(error = %err, "TOTP challenge sweep failed"),
            }
            match store.sweep_expired_tokens().await {
                Ok(swept) => {
                    if swept.total() > 0 {
                        tracing::info!(
                            access_tokens = swept.access_tokens,
                            refresh_tokens = swept.refresh_tokens,
                            ws_tickets = swept.ws_tickets,
                            "swept expired token rows"
                        );
                    }
                    record_sweep_run(&store, "token", swept.total() as i64).await;
                }
                Err(err) => tracing::warn!(error = %err, "token sweep failed"),
            }
            if let Err(err) = store.sweep_interactions().await {
                tracing::warn!(error = %err, "interaction sweep failed");
            }
        }
    });
}

/// How often an uploaded-but-never-attached attachment is swept. Uploading is
/// two-phase (bytes first, a message reference second), so an interrupted
/// compose leaves a real, if bounded, class of orphan this reclaims; see
/// `store::attachments` for the grace window and per-pass batch size.
const ATTACHMENT_SWEEP_INTERVAL: std::time::Duration = std::time::Duration::from_secs(60 * 60);

/// Runs the orphaned-attachment sweep in the background; see [`spawn_sweep`].
///
/// The database rows are removed first (inside the store call); this only
/// cleans up the backing files that removal freed, which is why it needs
/// `media` and not just `store`.
pub(crate) fn spawn_attachment_sweep(store: store::Store, media: media::Media) {
    spawn_sweep(ATTACHMENT_SWEEP_INTERVAL, move || {
        let store = store.clone();
        let media = media.clone();
        async move {
            match store.sweep_orphaned_attachments().await {
                Ok(freed) => {
                    if !freed.is_empty() {
                        tracing::info!(count = freed.len(), "swept orphaned attachment rows");
                    }
                    record_sweep_run(&store, "attachments", freed.len() as i64).await;
                    for hex in freed {
                        if let Err(err) = media.delete_attachment(&hex).await {
                            tracing::warn!(error = %err, attachment = %hex, "failed to delete a swept attachment file");
                        }
                    }
                }
                Err(err) => tracing::warn!(error = %err, "attachment sweep failed"),
            }
        }
    });
}

/// How often the canvas op log is compacted. Long, the same reasoning
/// [`TOKEN_SWEEP_INTERVAL`] gives: nothing depends on a `remove`, `clear` or
/// `restore` row going away promptly, this only bounds how far the log grows
/// for the life of a deployment. A read-triggered sweep (the analytics
/// sampling model) was considered and rejected: this is a real `DELETE` with
/// a cost proportional to what it reclaims, not a cheap read, and a channel
/// drawn in continuously but never read through whatever request would
/// trigger it would never be swept at all - the opposite of what bounding
/// growth needs.
const CANVAS_OP_SWEEP_INTERVAL: std::time::Duration = std::time::Duration::from_secs(6 * 60 * 60);

/// Runs the canvas op compaction sweep in the background; see [`spawn_sweep`].
pub(crate) fn spawn_canvas_op_sweep(store: store::Store) {
    spawn_sweep(CANVAS_OP_SWEEP_INTERVAL, move || {
        let store = store.clone();
        async move {
            match store.sweep_canvas_ops().await {
                Ok(swept) => {
                    if swept.total() > 0 {
                        tracing::info!(
                            restores = swept.restores,
                            removes = swept.removes,
                            clears = swept.clears,
                            "compacted canvas op rows"
                        );
                    }
                    record_sweep_run(&store, "canvas_ops", swept.total() as i64).await;
                }
                Err(err) => tracing::warn!(error = %err, "canvas op sweep failed"),
            }
        }
    });
}

/// How often a stale voice heartbeat is checked for. Short, unlike the token
/// and attachment sweeps: this bounds how long a terminated app's ghost
/// participant lingers, so the interval is part of that bound rather than
/// housekeeping on its own schedule; see `voice::heartbeat`.
const CALL_SWEEP_INTERVAL: std::time::Duration = std::time::Duration::from_secs(10);

/// Runs the stale-voice-call sweep in the background; see [`spawn_sweep`].
///
/// A deployment with no SFU configured never has anything to sweep, so this is
/// safe to spawn unconditionally.
pub(crate) fn spawn_call_sweep(voice: voice::VoiceService, hub: hub::Hub) {
    spawn_sweep(CALL_SWEEP_INTERVAL, move || {
        let voice = voice.clone();
        let hub = hub.clone();
        async move {
            sweep_stale_voice_calls(&voice, &hub).await;
        }
    });
}

/// One pass of the stale-call sweep, evicting every call whose heartbeat has
/// gone stale as of now.
pub async fn sweep_stale_voice_calls(voice: &voice::VoiceService, hub: &hub::Hub) {
    sweep_stale_voice_calls_at(voice, hub, std::time::Instant::now()).await;
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
) {
    let stale = voice.sweep_stale_calls_at(now);
    for (_, channel_id) in &stale {
        hub.publish(hub::Event::VoiceActivityChanged {
            channel_id: *channel_id,
        });
    }
    futures_util::stream::iter(stale)
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

/// How often the message retention window is applied. Long, the same
/// reasoning [`TOKEN_SWEEP_INTERVAL`] gives: a day-granularity setting has
/// no reason to be checked more often than this, and a deployment with the
/// window off pays only the one cheap config read every tick.
const MESSAGE_RETENTION_SWEEP_INTERVAL: std::time::Duration =
    std::time::Duration::from_secs(6 * 60 * 60);

/// Runs the message retention sweep in the background; see [`spawn_sweep`].
///
/// Unlike the other sweeps here, a pruned message is a state change a live
/// connection needs to see now, not merely reclaimed space, so this publishes
/// [`hub::Event::MessageDeleted`] for every message the sweep touched before
/// reclaiming its freed attachment files.
pub(crate) fn spawn_message_retention_sweep(
    store: store::Store,
    media: media::Media,
    hub: hub::Hub,
) {
    spawn_sweep(MESSAGE_RETENTION_SWEEP_INTERVAL, move || {
        let store = store.clone();
        let media = media.clone();
        let hub = hub.clone();
        async move {
            match store.sweep_message_retention().await {
                Ok(swept) => {
                    let pruned_count = swept.pruned.len();
                    if pruned_count > 0 || swept.ops_reclaimed > 0 {
                        tracing::info!(
                            pruned = pruned_count,
                            ops_reclaimed = swept.ops_reclaimed,
                            "pruned messages past the retention window"
                        );
                    }
                    record_sweep_run(&store, "message_retention", pruned_count as i64).await;
                    crate::forward_events::publish_detached(&store, &hub, &swept.detached).await;
                    for message in swept.pruned {
                        hub.publish(hub::Event::MessageDeleted {
                            channel_id: message.channel_id,
                            message_id: message.message_id,
                            op_seq: message.op_seq,
                        });
                        for hex in message.freed_attachments {
                            if let Err(err) = media.delete_attachment(&hex).await {
                                tracing::warn!(error = %err, attachment = %hex, "failed to delete a retention-freed attachment file");
                            }
                        }
                    }
                }
                Err(err) => tracing::warn!(error = %err, "message retention sweep failed"),
            }
        }
    });
}
