// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Housekeeping for voice sessions (decision 0091): ending the ones a missed
//! leave left open, and deleting closed ones past retention.

use crate::ids::{ChannelId, UserId};
use crate::store::{self, SessionScope, Store};
use crate::sweeps::spawn_sweep;

/// How often voice sessions past their retention are deleted.
const SWEEP_INTERVAL: std::time::Duration = std::time::Duration::from_secs(60 * 60);

/// Ends the voice sessions of members whose heartbeat went stale.
pub async fn close_stale_sessions(store: &Store, stale: &[(UserId, ChannelId)]) {
    let at = store::now_ms();
    for (user_id, channel_id) in stale {
        let scope = SessionScope::Member(*user_id, *channel_id);
        if let Err(err) = store.close_voice_sessions(scope, at).await {
            tracing::warn!(%err, "could not close a stale voice session");
        }
    }
}

/// Closes every session left open by a previous run, since the leaves that
/// would have ended them may have been missed while the server was down.
pub async fn reconcile_on_startup(store: &Store) {
    match store
        .close_voice_sessions(SessionScope::Everyone, store::now_ms())
        .await
    {
        Ok(closed) if !closed.is_empty() => {
            tracing::info!(
                count = closed.len(),
                "closed voice sessions left open at shutdown"
            );
        }
        Ok(_) => {}
        Err(err) => tracing::warn!(%err, "could not close voice sessions left open"),
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
