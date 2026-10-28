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

mod voice;
pub(crate) use voice::{
    spawn_call_history_sweep, spawn_call_sweep, spawn_ring_sweep, spawn_room_sweep,
};
pub use voice::{
    sweep_stale_call_rings, sweep_stale_call_rings_at, sweep_stale_voice_calls,
    sweep_stale_voice_calls_at,
};

use crate::{hub, media, store};

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
pub(crate) fn spawn_sweep<F, Fut>(interval: std::time::Duration, pass: F)
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
        async move { run_token_sweep_pass(&store).await }
    });
}

/// One pass of the token sweep, callable without the timer.
pub async fn run_token_sweep_pass(store: &store::Store) {
    // Same schedule and reasoning as the token sweep: a spent challenge grants nothing.
    match store.sweep_expired_totp_challenges().await {
        Ok(0) => {}
        Ok(swept) => tracing::info!(swept, "swept expired TOTP challenge rows"),
        Err(err) => tracing::warn!(error = %err, "TOTP challenge sweep failed"),
    }
    match store.sweep_dead_invites().await {
        Ok(0) => {}
        Ok(swept) => tracing::info!(swept, "swept spent, expired and revoked invites"),
        Err(err) => tracing::warn!(error = %err, "invite sweep failed"),
    }
    match store.sweep_login_throttle().await {
        Ok(0) => {}
        Ok(swept) => tracing::info!(swept, "swept stale login throttle rows"),
        Err(err) => tracing::warn!(error = %err, "login throttle sweep failed"),
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
            record_sweep_run(store, "token", swept.total() as i64).await;
        }
        Err(err) => tracing::warn!(error = %err, "token sweep failed"),
    }
    if let Err(err) = store.sweep_interactions().await {
        tracing::warn!(error = %err, "interaction sweep failed");
    }
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
        async move { run_attachment_sweep_pass(&store, &media).await }
    });
}

/// One pass of the orphaned-attachment sweep, callable without the timer.
pub async fn run_attachment_sweep_pass(store: &store::Store, media: &media::Media) {
    match store.sweep_orphaned_attachments().await {
        Ok(freed) => {
            if !freed.is_empty() {
                tracing::info!(count = freed.len(), "swept orphaned attachment rows");
            }
            record_sweep_run(store, "attachments", freed.len() as i64).await;
            for hex in freed {
                crate::blobs::release(store, media, &hex).await;
            }
        }
        Err(err) => tracing::warn!(error = %err, "attachment sweep failed"),
    }
    match crate::blobs::collect_garbage(store, media, std::time::SystemTime::now()).await {
        Ok(0) => {}
        Ok(count) => tracing::info!(count, "removed leaked attachment files"),
        Err(err) => tracing::warn!(error = %err, "attachment file scan failed"),
    }
    match media.uploads().sweep_expired(store::now_ms()).await {
        Ok(0) => {}
        Ok(count) => tracing::info!(count, "swept expired upload sessions"),
        Err(err) => tracing::warn!(error = %err, "upload session sweep failed"),
    }
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
        async move { run_message_retention_sweep_pass(&store, &media, &hub).await }
    });
}

/// Backlog the sweep lets a subscriber carry before it pauses publishing.
const PUBLISH_BACKLOG_LIMIT: usize = hub::CHANNEL_CAPACITY / 4;
/// How long one wait for the slowest subscriber may last before publishing resumes.
const PUBLISH_BACKLOG_MAX_WAIT: std::time::Duration = std::time::Duration::from_secs(2);
const PUBLISH_BACKLOG_POLL: std::time::Duration = std::time::Duration::from_millis(5);

/// Pauses a bulk publisher while a subscriber is far behind, so a big prune
/// cannot push one past [`hub::CHANNEL_CAPACITY`] and force it to resync.
/// Returns false when the wait timed out, meaning a subscriber has stalled.
async fn wait_for_publish_headroom(hub: &hub::Hub) -> bool {
    if hub.durable_backlog() < PUBLISH_BACKLOG_LIMIT {
        tokio::task::yield_now().await;
        return true;
    }
    let deadline = tokio::time::Instant::now() + PUBLISH_BACKLOG_MAX_WAIT;
    while hub.durable_backlog() >= PUBLISH_BACKLOG_LIMIT && tokio::time::Instant::now() < deadline {
        tokio::time::sleep(PUBLISH_BACKLOG_POLL).await;
    }
    hub.durable_backlog() < PUBLISH_BACKLOG_LIMIT
}

/// One pass of the message retention sweep, callable without the timer.
pub async fn run_message_retention_sweep_pass(
    store: &store::Store,
    media: &media::Media,
    hub: &hub::Hub,
) {
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
            record_sweep_run(store, "message_retention", pruned_count as i64).await;
            crate::forward_events::publish_detached(store, hub, &swept.detached).await;
            let mut paced = true;
            for message in swept.pruned {
                // A stalled subscriber would cost the full wait per message, so stop pacing for it.
                paced = paced && wait_for_publish_headroom(hub).await;
                if message.was_pinned {
                    hub.publish(hub::Event::MessageUnpinned {
                        channel_id: message.channel_id,
                        message_id: message.message_id,
                    });
                }
                hub.publish(hub::Event::MessageDeleted {
                    channel_id: message.channel_id,
                    message_id: message.message_id,
                    op_seq: message.op_seq,
                });
                for hex in message.freed_attachments {
                    crate::blobs::release(store, media, &hex).await;
                }
            }
        }
        Err(err) => tracing::warn!(error = %err, "message retention sweep failed"),
    }
}
