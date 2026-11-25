// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Keeps what a member on a call may publish at the SFU in step with their Speak and Use Canvas
//! rights. A token fixes both when it is minted, so a change after that has to be pushed.

use super::super::AppState;
use crate::ids::{ChannelId, UserId};
use crate::permissions::Permissions;
use crate::voice::{Grants, VoiceError};

/// Pushes the grants `held` allows unless the SFU is already known to hold them.
pub(in crate::http) async fn push_if_changed(
    state: &AppState,
    user_id: UserId,
    channel_id: ChannelId,
    held: Permissions,
) {
    let grants = Grants::from_permissions(held);
    if !state
        .voice
        .asked_calls()
        .grants_match(user_id, channel_id, grants)
    {
        push(state, user_id, channel_id, grants).await;
    }
}

/// Pushes the grants `held` allows whatever the SFU is thought to hold, for a connection that
/// came in on a renewed token whose grants are the ones it was first minted with.
pub(in crate::http) async fn push_for_renewed_token(
    state: &AppState,
    user_id: UserId,
    channel_id: ChannelId,
    held: Permissions,
) {
    push(state, user_id, channel_id, Grants::from_permissions(held)).await;
}

async fn push(state: &AppState, user_id: UserId, channel_id: ChannelId, grants: Grants) {
    match state
        .voice
        .set_participant_grants(channel_id, user_id, grants)
        .await
    {
        Ok(()) | Err(VoiceError::Unavailable) => {}
        Err(VoiceError::Internal(err)) => {
            tracing::warn!(%err, %channel_id, "could not update what a voice participant may publish");
        }
    }
}
