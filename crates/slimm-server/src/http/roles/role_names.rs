// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What a role may be called: a visible name that no member could read as a mention or as another role.

use super::super::AppState;
use super::super::error::ApiError;
use super::super::hidden_chars::is_hidden_char;
use crate::ids::RoleId;

pub(super) fn validate_role_name(name: &str) -> Result<&str, ApiError> {
    let trimmed = name.trim();
    if trimmed.is_empty() || trimmed.chars().count() > crate::limits::MAX_NAME_CHARS {
        return Err(ApiError::BadRequest("name must be 1 to 64 characters"));
    }
    if trimmed.chars().any(is_hidden_char) {
        return Err(ApiError::BadRequest(
            "name must not contain control or invisible characters",
        ));
    }
    Ok(trimmed)
}

/// Names a mention already means; `@everyone` itself keeps its own.
const RESERVED_ROLE_NAMES: [&str; 2] = ["everyone", "here"];

/// What a member would read a role name as, whatever its case or a leading `@`.
fn folded_role_name(name: &str) -> String {
    name.trim_start_matches('@').trim().to_lowercase()
}

/// Refuses `name` for `role_id` when it reads as a mention or as another role's name.
pub(super) async fn require_distinct_role_name(
    state: &AppState,
    name: &str,
    role_id: RoleId,
) -> Result<(), ApiError> {
    let folded = folded_role_name(name);
    let roles = state.store.list_roles().await?;
    let renaming_everyone = roles.iter().any(|r| r.id == role_id && r.is_everyone);
    if !renaming_everyone && RESERVED_ROLE_NAMES.contains(&folded.as_str()) {
        return Err(ApiError::BadRequest(
            "that name is reserved for @everyone and @here",
        ));
    }
    if roles
        .iter()
        .any(|r| r.id != role_id && folded_role_name(&r.name) == folded)
    {
        return Err(ApiError::Conflict("another role already has that name"));
    }
    Ok(())
}
