// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Channel category routes: list, create, rename/reposition, and soft-delete.
//!
//! Every mutation is gated on MANAGE_CHANNELS at the deployment level, the
//! same bit `http::channels` already uses for channel create/rename/delete -
//! a category is part of the same rail-management surface, not a new
//! permission of its own. `list` is not: a category carries no permission of
//! its own at all, so any authenticated caller may read the list, the same
//! openness `GET /channels` used to answer it with before it moved here.
//! See docs/decisions/0006-channel-categories.md.

use axum::Router;
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::StatusCode;
use axum::http::request::Parts;
use axum::routing::{get, patch};
use serde::{Deserialize, Serialize};

use super::AppState;
use super::error::ApiError;
use super::extract::{AUTHED_READ, Authed, AuthedLimited, Json, enforce};
use super::hidden_chars::is_hidden_char;
use super::messages::parse_uuid;
use crate::hub::Event;
use crate::ids::ChannelCategoryId;
use crate::permissions::Permissions;
use crate::ratelimit::Class;
use crate::store::ChannelCategory;

const CATEGORY_BODY_LIMIT: usize = 4 * 1024;
const CATEGORY_NAME_MAX_CHARS: usize = crate::limits::MAX_NAME_CHARS;

/// The category routes, mounted by [`super::router`].
pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/categories", get(list).post(create))
        .route("/categories/{category_id}", patch(update).delete(delete))
        .layer(DefaultBodyLimit::max(CATEGORY_BODY_LIMIT))
}

#[derive(Serialize)]
struct CategoryDto {
    id: String,
    name: String,
    position: i64,
    created_at: i64,
}

impl From<ChannelCategory> for CategoryDto {
    fn from(category: ChannelCategory) -> Self {
        Self {
            id: category.id.to_string(),
            name: category.name,
            position: category.position,
            created_at: category.created_at,
        }
    }
}

#[derive(Deserialize)]
struct CreateCategoryRequest {
    /// Client-generated UUIDv7 that makes the create idempotent on retry.
    /// Absent means the server mints one and this is always a fresh create.
    id: Option<String>,
    name: String,
}

#[derive(Deserialize)]
struct UpdateCategoryRequest {
    /// Absent leaves the name unchanged, the same "at least one, absent
    /// means untouched" convention `channels::UpdateChannelRequest` uses.
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    position: Option<i64>,
}

/// Lists every live category. Unfiltered by any permission, the same as the
/// list this used to ride inside `GET /channels`'s own response: a category
/// carries no permission of its own (see docs/IMPLIED-GAPS.md), so its name
/// and position are not privileged for anyone who can already authenticate.
async fn list(
    AuthedLimited(_ctx): AuthedLimited<AUTHED_READ>,
    State(state): State<AppState>,
) -> Result<Json<Vec<CategoryDto>>, ApiError> {
    let categories = state
        .store
        .list_categories()
        .await?
        .into_iter()
        .map(CategoryDto::from)
        .collect();
    Ok(Json(categories))
}

async fn create(
    Authed(ctx): Authed,
    parts: Parts,
    State(state): State<AppState>,
    Json(req): Json<CreateCategoryRequest>,
) -> Result<Json<CategoryDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    require_manage_channels(&state, ctx.user_id).await?;

    let name = validate_category_name(&req.name)?;
    let id = req
        .id
        .as_deref()
        .map(|raw| parse_uuid(raw).map(ChannelCategoryId))
        .transpose()?
        .unwrap_or_else(ChannelCategoryId::generate);

    let created = state.store.create_category_with_id(id, name).await?;
    // An idempotent retry must not fan out again; see the note on `CreatedCategory::fresh`.
    if created.fresh {
        state.hub.publish(Event::CategoryChanged);
    }
    Ok(Json(created.category.into()))
}

async fn update(
    Authed(ctx): Authed,
    parts: Parts,
    Path(category_id): Path<String>,
    State(state): State<AppState>,
    Json(req): Json<UpdateCategoryRequest>,
) -> Result<Json<CategoryDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    require_manage_channels(&state, ctx.user_id).await?;
    let category_id = ChannelCategoryId(parse_uuid(&category_id)?);

    let name = req
        .name
        .as_deref()
        .map(validate_category_name)
        .transpose()?;
    if name.is_none() && req.position.is_none() {
        return Err(ApiError::BadRequest("nothing to update"));
    }

    let category = state
        .store
        .update_category(category_id, name, req.position)
        .await?
        .ok_or(ApiError::NotFound("category not found"))?;
    state.hub.publish(Event::CategoryChanged);
    Ok(Json(category.into()))
}

/// Soft-deletes a category. Its channels are never deleted with it - they
/// fall back to uncategorised, per docs/decisions/0006-channel-categories.md.
/// Idempotent on one already deleted, the same convention `deleteChannel`
/// follows.
async fn delete(
    Authed(ctx): Authed,
    parts: Parts,
    Path(category_id): Path<String>,
    State(state): State<AppState>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    require_manage_channels(&state, ctx.user_id).await?;
    let category_id = ChannelCategoryId(parse_uuid(&category_id)?);

    match state.store.delete_category(category_id).await {
        Ok(true) => {
            state.hub.publish(Event::CategoryChanged);
            Ok(StatusCode::NO_CONTENT)
        }
        Ok(false) => Ok(StatusCode::NO_CONTENT),
        Err(e) => Err(e.into()),
    }
}

async fn require_manage_channels(
    state: &AppState,
    user_id: crate::ids::UserId,
) -> Result<(), ApiError> {
    if !state
        .store
        .base_permissions(user_id)
        .await?
        .contains(Permissions::MANAGE_CHANNELS)
    {
        return Err(ApiError::Forbidden);
    }
    Ok(())
}

fn validate_category_name(name: &str) -> Result<&str, ApiError> {
    let trimmed = name.trim();
    if trimmed.is_empty() || trimmed.chars().count() > CATEGORY_NAME_MAX_CHARS {
        return Err(ApiError::BadRequest("name must be 1 to 64 characters"));
    }
    if trimmed.chars().any(is_hidden_char) {
        return Err(ApiError::BadRequest(
            "name must not contain control or invisible characters",
        ));
    }
    Ok(trimmed)
}
