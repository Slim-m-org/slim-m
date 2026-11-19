// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Housekeeping for voice sessions (decision 0091): ending the ones a missed
//! leave left open, and deleting closed ones past retention.

use std::collections::BTreeSet;

use crate::hub::{Event, Hub};
use crate::ids::{ChannelId, UserId};
use crate::store::{self, SessionScope, Store, VoiceSession};
use crate::sweeps::spawn_sweep;
use crate::voice::VoiceService;

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
/// opens one again for each member the SFU still has on that same connection.
pub async fn reconcile_on_startup(store: &Store, voice: &VoiceService) {
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
    let reopened = reopen_live(store, voice, &closed, at).await;
    tracing::info!(
        count = closed.len(),
        reopened,
        "closed voice sessions left open at shutdown"
    );
}

/// A call outlives a restart of this server, so its members' sessions carry on in a new row
/// from `at`. An SFU that cannot answer leaves the sessions closed.
async fn reopen_live(store: &Store, voice: &VoiceService, closed: &[VoiceSession], at: i64) -> u64 {
    let channels: BTreeSet<ChannelId> = closed.iter().map(|s| s.channel_id).collect();
    let mut reopened = 0;
    for channel_id in channels {
        // One unanswered read is the last: startup must not wait out a timeout per channel.
        let Ok(listed) = voice.list_participants(channel_id).await else {
            break;
        };
        let still_on = closed.iter().filter(|session| {
            session.channel_id == channel_id
                && listed
                    .iter()
                    .any(|p| p.user_id == session.user_id && p.sid == session.sid)
        });
        for session in still_on {
            match store
                .open_voice_session(channel_id, session.user_id, &session.sid, at)
                .await
            {
                Ok(opened) => reopened += u64::from(opened),
                Err(err) => tracing::warn!(%err, "could not carry a voice session over a restart"),
            }
        }
    }
    reopened
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
