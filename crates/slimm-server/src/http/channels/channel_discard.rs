// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `discard_canvas` on a channel update: the settings write and the board clear commit together (decision 0139).

use super::super::AppState;
use super::super::canvas::canvas_ops_write::publish;
use super::super::error::ApiError;
use crate::ids::{ChannelId, UserId};
use crate::store::{ChannelPatch, DiscardError};

/// Applies `patch` and clears the hidden board in one transaction, then tells the sockets the board was cleared.
///
/// The `Cleared` frame goes out before anything else is awaited, as a submitted clear's does.
pub(super) async fn discard_hidden_canvas(
    state: &AppState,
    channel_id: ChannelId,
    patch: ChannelPatch<'_>,
    actor_id: UserId,
) -> Result<crate::store::Channel, ApiError> {
    let discarded = match state
        .store
        .update_channel_discarding_canvas(channel_id, patch, actor_id)
        .await
    {
        Ok(discarded) => discarded,
        Err(DiscardError::NotFound) => return Err(ApiError::NotFound("channel not found")),
        Err(DiscardError::NotHidden) => {
            return Err(ApiError::BadRequest("clear an open canvas from the board"));
        }
        Err(DiscardError::Internal(err)) => return Err(err.into()),
    };
    if discarded.op.fresh && discarded.op.affected > 0 {
        publish(state, channel_id, discarded.op.id, &discarded.op);
    }
    Ok(discarded.channel)
}
