// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What a role may be called: a visible name that no member could read as a mention or as another role.

use super::super::AppState;
use super::super::error::ApiError;
use super::super::hidden_chars::{draws_nothing, is_hidden_char};
use crate::ids::RoleId;
use crate::store::fold_role_name as folded_role_name;

/// The refusal for a name another role already reads as.
pub(in crate::http) const ROLE_NAME_TAKEN: &str = "another role already has that name";

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
    if draws_nothing(trimmed) {
        return Err(ApiError::BadRequest("name must not be blank"));
    }
    Ok(trimmed)
}

/// Names a mention already means; `@everyone` itself keeps its own.
const RESERVED_ROLE_NAMES: [&str; 2] = ["everyone", "here"];

/// Refuses `name` for `role_id` when it reads as a mention or as another role's name.
///
/// A name that reads the same as the role's own passes, so a role named before
/// this rule can still be edited by a client that resends its name.
pub(super) async fn require_distinct_role_name(
    state: &AppState,
    name: &str,
    role_id: RoleId,
) -> Result<(), ApiError> {
    let folded = folded_role_name(name);
    let roles = state.store.list_roles().await?;
    let own = roles.iter().find(|r| r.id == role_id);
    if own.is_some_and(|r| folded_role_name(&r.name) == folded) {
        return Ok(());
    }
    let renaming_everyone = own.is_some_and(|r| r.is_everyone);
    if !renaming_everyone && RESERVED_ROLE_NAMES.contains(&folded.as_str()) {
        return Err(ApiError::BadRequest(
            "that name is reserved for @everyone and @here",
        ));
    }
    if roles
        .iter()
        .any(|r| r.id != role_id && folded_role_name(&r.name) == folded)
    {
        return Err(ApiError::Conflict(ROLE_NAME_TAKEN));
    }
    Ok(())
}
