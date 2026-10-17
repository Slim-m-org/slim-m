// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Small checks shared by the report moderation routes.

use super::super::AppState;
use super::super::error::ApiError;
use crate::ids::UserId;
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
