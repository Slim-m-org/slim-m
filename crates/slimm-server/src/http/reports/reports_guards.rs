// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Small checks shared by the report moderation routes.

use super::super::AppState;
use super::super::error::ApiError;
use super::MODERATES_CHANNEL;
use crate::ids::{ChannelId, UserId};
use crate::permissions::Permissions;

/// 409 for a report somebody already closed, 404 for one that never existed.
pub(in crate::http) async fn missing_or_closed(
    state: &AppState,
    report_id: uuid::Uuid,
) -> Result<ApiError, ApiError> {
    Ok(if state.store.report_exists(report_id).await? {
        ApiError::Conflict("that report is already resolved")
    } else {
        ApiError::NotFound("report not found")
    })
}

pub(in crate::http) async fn require_manage_messages(
    state: &AppState,
    user_id: UserId,
) -> Result<(), ApiError> {
    if !state
        .store
        .base_permissions(user_id)
        .await?
        .contains(Permissions::MANAGE_MESSAGES)
    {
        return Err(ApiError::Forbidden);
    }
    Ok(())
}

/// Whether a base-level moderator may see or act on a report in this channel.
///
/// The caller has already passed the deployment-wide `MANAGE_MESSAGES` check.
/// A report in a live text or voice channel is further restricted to that
/// channel's own moderators, so a moderator excluded from one channel cannot
/// reach into it. A report in a DM or a since-deleted channel has no such
/// moderators to defer to, so it stays with the deployment moderators rather
/// than falling into a per-channel check that grants it to nobody. That hole
/// was accepting DM harassment reports and hiding them forever.
pub(in crate::http) async fn report_visible_in(
    state: &AppState,
    user_id: UserId,
    channel_id: ChannelId,
) -> bool {
    match state.store.channel_scopes_moderation(channel_id).await {
        Ok(false) => true,
        Ok(true) => state
            .store
            .has_permission(user_id, channel_id, MODERATES_CHANNEL)
            .await
            .unwrap_or(false),
        Err(_) => false,
    }
}
