// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Housekeeping for voice sessions (decision 0091): ending the ones a missed
//! leave left open, and deleting closed ones past retention.

use std::collections::BTreeSet;

use crate::hub::{Event, Hub};
use crate::ids::{ChannelId, UserId};
use crate::store::{self, SessionScope, Store, VoiceSession};
use crate::sweeps::spawn_sweep;
use crate::voice::{VoiceError, VoiceService};

/// How often voice sessions past their retention are deleted.
const SWEEP_INTERVAL: std::time::Duration = std::time::Duration::from_secs(60 * 60);

/// Tells subscribed modules that these sessions have ended.
pub fn publish_closed(hub: &Hub, closed: &[VoiceSession]) {
    for session in closed {
        hub.publish(Event::VoiceSessionClosed {
            session_id: session.id,
            user_id: session.user_id,
            channel_id: session.channel_id,
            joined_at_ms: session.joined_at,
            left_at_ms: session.left_at.unwrap_or(session.joined_at),
            alone_ms: session.alone_ms,
        });
    }
}

/// Ends the voice sessions of members whose heartbeat went stale.
pub async fn close_stale_sessions(store: &Store, hub: &Hub, stale: &[(UserId, ChannelId)]) {
    let at = store::now_ms();
    for (user_id, channel_id) in stale {
        let scope = SessionScope::Member(*user_id, *channel_id);
        match store.close_voice_sessions(scope, at).await {
            Ok(closed) => publish_closed(hub, &closed),
            Err(err) => tracing::warn!(%err, "could not close a stale voice session"),
        }
    }
}

/// Closes every session left open by a previous run, since the leaves that
/// would have ended them may have been missed while the server was down, then
/// opens one again for each member the SFU still has on those calls.
///
/// Tells modules about the closes, so call this once their consumer is subscribed. A call the
/// SFU did not answer for stays closed until [`retry_deferred_reopens`] reaches it.
pub async fn reconcile_on_startup(store: &Store, voice: &VoiceService, hub: &Hub) {
    let at = store::now_ms();
    let closed = match store.close_voice_sessions(SessionScope::Everyone, at).await {
        Ok(closed) => closed,
        Err(err) => {
            tracing::warn!(%err, "could not close voice sessions left open");
            return;
        }
    };
    if closed.is_empty() {
        return;
    }
    publish_closed(hub, &closed);
    let reopened = reopen_live(store, voice, &closed, at).await;
    tracing::info!(
        count = closed.len(),
        reopened,
        "closed voice sessions left open at shutdown"
    );
}

/// A call outlives a restart of this server, so everyone the SFU lists on a call that had a
/// session open gets a new row from `at`, under the connection they have now: a join or a
/// reconnect made while this server was down sent a webhook nobody received.
async fn reopen_live(store: &Store, voice: &VoiceService, closed: &[VoiceSession], at: i64) -> u64 {
    let channels: BTreeSet<ChannelId> = closed.iter().map(|s| s.channel_id).collect();
    let mut reopened = 0;
    for (asked, channel_id) in channels.iter().enumerate() {
        match reopen_channel(store, voice, *channel_id, at).await {
            Ok(opened) => reopened += opened,
            Err(err) => {
                // One unanswered read is the last: startup must not wait out a timeout per channel.
                tracing::warn!(
                    ?err,
                    left_closed = channels.len() - asked,
                    "the sfu did not answer at startup, so the calls not yet asked about keep their sessions closed until a member beats"
                );
                for pending in channels.iter().skip(asked) {
                    voice.live_state().defer_session_reopen(*pending);
                }
                break;
            }
        }
    }
    reopened
}

async fn reopen_channel(
    store: &Store,
    voice: &VoiceService,
    channel_id: ChannelId,
    at: i64,
) -> Result<u64, VoiceError> {
    let mut reopened = 0;
    for member in voice.list_participants(channel_id).await? {
        match store
            .open_voice_session(channel_id, member.user_id, &member.sid, at)
            .await
        {
            Ok(opened) => reopened += u64::from(opened),
            Err(err) => tracing::warn!(%err, "could not carry a voice session over a restart"),
        }
    }
    Ok(reopened)
}

/// Opens the sessions of a call startup could not read off the SFU; a read that fails again
/// leaves it for the next try and answers false.
pub async fn reopen_deferred(store: &Store, voice: &VoiceService, channel_id: ChannelId) -> bool {
    if !voice.live_state().take_session_reopen(channel_id) {
        return true;
    }
    if let Err(err) = reopen_channel(store, voice, channel_id, store::now_ms()).await {
        tracing::warn!(?err, %channel_id, "could not reopen a voice call's sessions");
        voice.live_state().defer_session_reopen(channel_id);
        return false;
    }
    true
}

/// Retries every call still waiting to be reopened, stopping at the first the SFU does not answer for.
pub async fn retry_deferred_reopens(store: &Store, voice: &VoiceService) {
    for channel_id in voice.live_state().deferred_session_reopens() {
        if !reopen_deferred(store, voice, channel_id).await {
            return;
        }
    }
}

/// Runs the retention sweep in the background; see [`spawn_sweep`].
pub(crate) fn spawn_retention_sweep(store: Store) {
    spawn_sweep(SWEEP_INTERVAL, move || {
        let store = store.clone();
        async move {
            if let Err(err) = store.sweep_voice_sessions().await {
                tracing::warn!(%err, "could not sweep old voice sessions");
            }
        }
    });
}
