// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A bot's read-only view of one member's effective permissions, so a
//! permission-gated command works without the bot holding MANAGE_ROLES.

use axum::Router;
use axum::extract::{Path, State};
use axum::routing::get;
use serde::{Deserialize, Serialize};

use super::AppState;
use super::error::ApiError;
use super::extract::{AUTHED_READ, AuthedLimited, Json, Query};
use super::messages::parse_uuid;
use crate::ids::{ChannelId, UserId};
use crate::permissions::{Permissions, mask_unless_viewable};

pub fn routes() -> Router<AppState> {
    Router::new().route("/members/{user_id}/permissions", get(get_permissions))
}

#[derive(Deserialize)]
struct MemberPermissionsParams {
    channel_id: Option<String>,
}

#[derive(Serialize)]
struct MemberPermissionsDto {
    user_id: String,
    /// The member's permission bitmask, deployment-wide or in `channel_id`, timeout already subtracted.
    permissions: i64,
    /// Echoes the scoping channel, so a bot can tell this server applied it.
    #[serde(skip_serializing_if = "Option::is_none")]
    channel_id: Option<String>,
}

/// Bot accounts only: a person reads their own bits from `/me`, and nothing
/// here can change a role.
async fn get_permissions(
    AuthedLimited(ctx): AuthedLimited<AUTHED_READ>,
    State(state): State<AppState>,
    Path(user_id): Path<String>,
    Query(params): Query<MemberPermissionsParams>,
) -> Result<Json<MemberPermissionsDto>, ApiError> {
    if !state.store.is_bot(ctx.user_id).await? {
        return Err(ApiError::Forbidden);
    }
    let user_id = UserId(parse_uuid(&user_id)?);
    let channel_id = params
        .channel_id
        .as_deref()
        .map(|raw| parse_uuid(raw).map(ChannelId))
        .transpose()?;
    if state.store.user_profile(user_id).await?.is_none() {
        return Err(ApiError::NotFound("no such member"));
    }
    let permissions = match channel_id {
        Some(channel_id) => in_channel(&state, ctx.user_id, user_id, channel_id).await?,
        None => state.store.base_permissions(user_id).await?,
    };
    Ok(Json(MemberPermissionsDto {
        user_id: user_id.to_string(),
        permissions: permissions.bits(),
        channel_id: channel_id.map(|id| id.to_string()),
    }))
}

/// Zero unless both the bot and the member can view the channel, so this
/// answers a hidden channel exactly like a missing one (decision 0011).
async fn in_channel(
    state: &AppState,
    bot_id: UserId,
    user_id: UserId,
    channel_id: ChannelId,
) -> Result<Permissions, ApiError> {
    let bot = state
        .store
        .permissions_in_channel(bot_id, channel_id)
        .await?;
    if !bot.contains(Permissions::VIEW_CHANNEL) {
        return Ok(Permissions::NONE);
    }
    let member = state
        .store
        .permissions_in_channel(user_id, channel_id)
        .await?;
    Ok(mask_unless_viewable(member))
}
