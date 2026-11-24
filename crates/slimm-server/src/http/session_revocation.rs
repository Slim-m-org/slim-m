// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What every revocation of a session owes after it commits: the sockets it holds close, and a
//! call a device of the account joined ends once that device holds no live session.

use super::AppState;
use super::voice::voice_access::evict_calls_without_live_device;
use crate::hub::Event;
use crate::ids::{SessionId, UserId};

/// `user_id` lost `sessions`.
pub(in crate::http) fn sessions_revoked(state: &AppState, user_id: UserId, sessions: &[SessionId]) {
    if sessions.is_empty() {
        return;
    }
    for session_id in sessions {
        state.hub.publish(Event::SessionRevoked(*session_id));
    }
    end_signed_out_calls(state, vec![user_id]);
}

/// [`sessions_revoked`] for a caller that holds the sessions but not their owner.
pub(in crate::http) fn sessions_revoked_by_id(state: &AppState, sessions: Vec<SessionId>) {
    if sessions.is_empty() {
        return;
    }
    for session_id in &sessions {
        state.hub.publish(Event::SessionRevoked(*session_id));
    }
    let state = state.clone();
    tokio::spawn(async move {
        match state.store.session_owners(&sessions).await {
            Ok(owners) => end_signed_out_calls_now(&state, owners).await,
            Err(err) => tracing::warn!(%err, "could not find who held revoked sessions"),
        }
    });
}

/// `user_id` lost every session but `kept`, including any a revocation before this one left a socket on.
pub(in crate::http) fn account_sessions_revoked(
    state: &AppState,
    user_id: UserId,
    kept: Option<SessionId>,
) {
    state
        .hub
        .publish(Event::AccountSessionsRevoked { user_id, kept });
    end_signed_out_calls(state, vec![user_id]);
}

/// Detached: the SFU is slow next to the revocation the caller already committed.
fn end_signed_out_calls(state: &AppState, users: Vec<UserId>) {
    let state = state.clone();
    tokio::spawn(async move { end_signed_out_calls_now(&state, users).await });
}

async fn end_signed_out_calls_now(state: &AppState, users: Vec<UserId>) {
    for user_id in users {
        evict_calls_without_live_device(state, user_id).await;
    }
}
