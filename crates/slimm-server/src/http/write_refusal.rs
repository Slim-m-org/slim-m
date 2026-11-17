// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Saying why a write was refused, rather than a bare 403, wherever the
//! reason tells the caller nothing they could not already see: a timeout, a
//! block in a DM they can read, a group they left after posting in it.

use axum::http::StatusCode;

use super::AppState;
use super::error::ApiError;
use crate::ids::{ChannelId, UserId};
use crate::permissions::Permissions;
use crate::store::{DM_CHANNEL_KIND, TIMEOUT_DENY};

/// Mirrors `ForbiddenException.blockedCode` in the client.
const BLOCKED_CODE: &str = "blocked";
/// Mirrors `ForbiddenException.leftGroupCode` in the client.
const LEFT_GROUP_CODE: &str = "left_group";

/// Passes when `user_id` holds `needed` in `channel_id`, else answers [`refusal`].
pub(in crate::http) async fn require(
    state: &AppState,
    user_id: UserId,
    channel_id: ChannelId,
    needed: Permissions,
) -> Result<(), ApiError> {
    let held = state
        .store
        .permissions_in_channel(user_id, channel_id)
        .await?;
    match held.contains(needed) {
        true => Ok(()),
        false => Err(refusal(state, user_id, channel_id, needed.remove(held)).await?),
    }
}

/// The 403 for `user_id` missing `missing` in `channel_id`: a reasoned one when
/// the caller can see the channel (or posted in the group they left), else the
/// bare refusal a missing channel also gets, so nothing hidden is confirmed.
pub(in crate::http) async fn refusal(
    state: &AppState,
    user_id: UserId,
    channel_id: ChannelId,
    missing: Permissions,
) -> Result<ApiError, ApiError> {
    if missing.contains(Permissions::VIEW_CHANNEL) {
        let left = state
            .store
            .is_former_group_dm_poster(user_id, channel_id)
            .await?;
        return Ok(match left {
            true => coded("you are no longer in this group", LEFT_GROUP_CODE),
            false => ApiError::Forbidden,
        });
    }
    if missing.intersects(TIMEOUT_DENY)
        && let Some(timeout) = state.store.member_timeout(user_id).await?
    {
        return Ok(ApiError::TimedOut {
            until: timeout.until,
            reason: timeout.reason,
        });
    }
    let is_dm = state
        .store
        .channel(channel_id)
        .await?
        .is_some_and(|c| c.kind == DM_CHANNEL_KIND);
    if is_dm
        && !state
            .store
            .dm_permissions(user_id, channel_id)
            .await?
            .contains(Permissions::SEND_MESSAGES)
    {
        return Ok(coded("one of you has blocked the other", BLOCKED_CODE));
    }
    Ok(ApiError::Forbidden)
}

fn coded(message: &'static str, code: &'static str) -> ApiError {
    ApiError::Coded {
        status: StatusCode::FORBIDDEN,
        message,
        code,
    }
}
