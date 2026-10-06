// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Per-channel slow mode: the range check `channels::update` applies to an
//! incoming `slow_mode_seconds`, and the check `messages::send` applies to a
//! fresh send. No route of its own - slow mode is set through the existing
//! `PATCH /channels/{channel_id}` and enforced inline in `POST
//! /channels/{channel_id}/messages`.

use super::AppState;
use super::error::ApiError;
use crate::ids::{ChannelId, UserId};
use crate::permissions::Permissions;
use crate::store::{now_ms, slow_mode_retry_after_seconds};

/// The highest interval a channel may be set to: six hours. A policy choice,
/// not a hard invariant, so it lives here rather than as a `CHECK` in the
/// migration - the same split `screen_share_max_height` and
/// `canvas_object_cap` use.
pub(crate) const SLOW_MODE_MAX_SECONDS: i64 = 6 * 60 * 60;

/// Bounds a `slow_mode_seconds` update. Refused outright rather than
/// clamped: a caller asking for a week's interval almost certainly mistyped
/// units, and silently capping it would leave them believing they set what
/// they asked for.
pub(crate) fn validate_slow_mode_seconds(seconds: i64) -> Result<i64, ApiError> {
    if !(0..=SLOW_MODE_MAX_SECONDS).contains(&seconds) {
        return Err(ApiError::BadRequest(
            "slow_mode_seconds must be between 0 and 21600",
        ));
    }
    Ok(seconds)
}

/// Refuses a fresh send that arrives before the channel's slow-mode interval
/// has elapsed since `author_id`'s own last message here, deleted ones
/// included. Returns the window to enforce again inside the send transaction
/// (`NewMessage::with_slow_mode`), which is the authoritative check: this one
/// only answers early. `None` when slow mode is off, or when `author_id`
/// holds `MANAGE_CHANNELS` in this channel - the one lever between "nothing"
/// and a full timeout, so its holder is exempt from the lesser one too.
///
/// Never called for an idempotent retry of an already-stored send; see
/// `messages::send`'s own `stored_already` guard, which decides that before
/// reaching here.
pub(crate) async fn enforce_slow_mode(
    state: &AppState,
    channel_id: ChannelId,
    author_id: UserId,
) -> Result<Option<i64>, ApiError> {
    let seconds = state.store.channel_slow_mode_seconds(channel_id).await?;
    if seconds <= 0 {
        return Ok(None);
    }
    if state
        .store
        .has_permission(author_id, channel_id, Permissions::MANAGE_CHANNELS)
        .await?
    {
        return Ok(None);
    }
    let window_ms = seconds * 1000;
    if let Some(last_sent_at) = state.store.last_message_at(channel_id, author_id).await?
        && let Some(retry_after_seconds) =
            slow_mode_retry_after_seconds(window_ms, last_sent_at, now_ms())
    {
        return Err(ApiError::SlowMode {
            retry_after_seconds,
        });
    }
    Ok(Some(window_ms))
}
