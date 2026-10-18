// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A bot's read-only view of one member's effective permissions, so a
//! permission-gated command works without the bot holding MANAGE_ROLES.

use axum::Router;
use axum::extract::{Path, State};
use axum::routing::get;
use serde::Serialize;

use super::AppState;
use super::error::ApiError;
use super::extract::{AUTHED_READ, AuthedLimited, Json};
use super::messages::parse_uuid;
use crate::ids::UserId;

pub fn routes() -> Router<AppState> {
    Router::new().route("/members/{user_id}/permissions", get(get_permissions))
}

#[derive(Serialize)]
struct MemberPermissionsDto {
    user_id: String,
    /// The member's deployment-wide permission bitmask, timeout already subtracted.
    permissions: i64,
}

/// Bot accounts only: a person reads their own bits from `/me`, and nothing
/// here can change a role.
async fn get_permissions(
    AuthedLimited(ctx): AuthedLimited<AUTHED_READ>,
    State(state): State<AppState>,
    Path(user_id): Path<String>,
) -> Result<Json<MemberPermissionsDto>, ApiError> {
    if !state.store.is_bot(ctx.user_id).await? {
        return Err(ApiError::Forbidden);
    }
    let user_id = UserId(parse_uuid(&user_id)?);
    if state.store.user_profile(user_id).await?.is_none() {
        return Err(ApiError::NotFound("no such member"));
    }
    let permissions = state.store.base_permissions(user_id).await?;
    Ok(Json(MemberPermissionsDto {
        user_id: user_id.to_string(),
        permissions: permissions.bits(),
    }))
}
