// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `GET /roles/{role_id}/preview`: the categories and channels a member holding only `@everyone`
//! and that role would see, trimmed to what the caller sees. Structure only; see decision 0124.

use std::collections::HashSet;

use axum::Router;
use axum::extract::{Path, State};
use axum::routing::get;
use serde::Serialize;

use super::super::AppState;
use super::super::categories::{CategoryDto, visible_categories};
use super::super::error::ApiError;
use super::super::extract::{AUTHED_READ, AuthedLimited, Json, require_manage_roles};
use super::super::messages::parse_uuid;
use super::super::role_ladder::Ladder;
use crate::ids::{ChannelCategoryId, ChannelId, RoleId, UserId};
use crate::permissions::Permissions;
use crate::store::{Channel, ChannelCategory};

/// Opening the preview again within this window does not add a second audit row.
const SAME_PREVIEW_WINDOW_MS: i64 = 10 * 60 * 1000;

/// The role-preview route, mounted by [`super::super::router`].
pub fn routes() -> Router<AppState> {
    Router::new().route("/roles/{role_id}/preview", get(preview))
}

#[derive(Serialize)]
struct RolePreviewDto {
    role_id: String,
    /// The role's deployment-level grant together with `@everyone`'s.
    permissions: i64,
    categories: Vec<CategoryDto>,
    channels: Vec<PreviewChannelDto>,
}

#[derive(Serialize)]
struct PreviewChannelDto {
    id: String,
    name: String,
    kind: String,
    position: i64,
    category_id: Option<String>,
    /// The role's effective bits in this channel; VIEW_CHANNEL is always among them.
    permissions: i64,
    restricted: bool,
}

impl PreviewChannelDto {
    fn new(channel: Channel, permissions: Permissions, restricted: bool) -> Self {
        Self {
            id: channel.id.to_string(),
            name: channel.name,
            kind: channel.kind,
            position: channel.position,
            category_id: channel.category_id.map(|id| id.to_string()),
            permissions: permissions.bits(),
            restricted,
        }
    }
}

/// Needs MANAGE_ROLES (ADMINISTRATOR implies it) and a role below the caller's highest.
async fn preview(
    AuthedLimited(ctx): AuthedLimited<AUTHED_READ>,
    Path(role_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<RolePreviewDto>, ApiError> {
    let caller_base = require_manage_roles(&state, ctx.user_id).await?;
    let role_id = RoleId(parse_uuid(&role_id)?);
    let role = state
        .store
        .role(role_id)
        .await?
        .ok_or(ApiError::NotFound("role not found"))?;
    Ladder::of(&state, ctx.user_id).await?.reach(&role)?;

    let preview = state.store.preview_role(&role).await?;
    let categories = state.store.list_categories().await?;
    let caller_sees = CallerView::load(&state, ctx.user_id, caller_base, &categories).await?;

    let channels: Vec<(Channel, Permissions, bool)> = preview
        .channels
        .into_iter()
        .filter(|(channel, perms, _)| {
            perms.contains(Permissions::VIEW_CHANNEL) && caller_sees.channels.contains(&channel.id)
        })
        .collect();
    let holding: HashSet<ChannelCategoryId> = channels
        .iter()
        .filter_map(|(channel, _, _)| channel.category_id)
        .collect();
    let manages = preview.base.contains(Permissions::MANAGE_CHANNELS);
    let role_sees = visible_categories(&categories, manages, &holding);

    state
        .store
        .record_admin_change_unless_recent(
            ctx.user_id,
            ("role.preview", &role.id.to_string()),
            "{}",
            SAME_PREVIEW_WINDOW_MS,
        )
        .await?;

    Ok(Json(RolePreviewDto {
        role_id: role.id.to_string(),
        permissions: preview.base.bits(),
        categories: categories
            .into_iter()
            .filter(|c| role_sees.contains(&c.id) && caller_sees.categories.contains(&c.id))
            .map(CategoryDto::from)
            .collect(),
        channels: channels
            .into_iter()
            .map(|(channel, perms, restricted)| PreviewChannelDto::new(channel, perms, restricted))
            .collect(),
    }))
}

/// What the caller's own `GET /channels` and `GET /categories` would list, so no name leaks upward.
struct CallerView {
    channels: HashSet<ChannelId>,
    categories: HashSet<ChannelCategoryId>,
}

impl CallerView {
    async fn load(
        state: &AppState,
        caller: UserId,
        caller_base: Permissions,
        categories: &[ChannelCategory],
    ) -> Result<Self, ApiError> {
        let visible = state.store.visible_channels(caller).await?;
        let holding = visible.iter().filter_map(|c| c.category_id).collect();
        let manages = caller_base.contains(Permissions::MANAGE_CHANNELS);
        Ok(Self {
            channels: visible.into_iter().map(|c| c.id).collect(),
            categories: visible_categories(categories, manages, &holding),
        })
    }
}
