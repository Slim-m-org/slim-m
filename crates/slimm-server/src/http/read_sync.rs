// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Moving an account's read marker and telling its other devices.

use super::AppState;
use super::error::ApiError;
use crate::ids::{ChannelId, UserId};

/// Advances `user_id`'s marker in `channel_id` and fans the result out to that
/// account's own sessions, so a badge clears on every device and not only the
/// one that read. The frame carries the stored marker, which is monotonic and
/// clamped, not the requested `seq`. A mark that moves nothing publishes
/// nothing: the frame wakes every socket on the shared channel.
pub(super) async fn advance_and_announce(
    state: &AppState,
    user_id: UserId,
    channel_id: ChannelId,
    seq: i64,
) -> Result<(), ApiError> {
    crate::read_announce::advance_and_announce(&state.store, &state.hub, user_id, channel_id, seq)
        .await?;
    Ok(())
}

/// Your own message is never unread to you, on this device or any other.
///
/// Best-effort: the message already landed, a missed marker only leaves a
/// badge, and the next read fixes it, so a failure must not fail the send.
pub(super) async fn advance_for_author(
    state: &AppState,
    author_id: UserId,
    message: &crate::store::Message,
) {
    let advanced = advance_and_announce(state, author_id, message.channel_id, message.seq.0).await;
    if advanced.is_err() {
        tracing::warn!(channel_id = %message.channel_id, "failed to advance the author's read marker");
    }
}
