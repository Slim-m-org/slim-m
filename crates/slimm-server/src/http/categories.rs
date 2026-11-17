// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Channel category routes (decisions 0006 and 0120). Every mutation needs
//! deployment-level MANAGE_CHANNELS, checked before any id in the body is read.

use std::collections::HashSet;

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
use crate::store::{CategoryUpdate, CategoryWriteError, ChannelCategory};

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
pub(super) struct CategoryDto {
    id: String,
    name: String,
    position: i64,
    created_at: i64,
    /// Always sent, null for a top-level category, so a client can tell this
    /// server nests from an older one that omits the key.
    parent_id: Option<String>,
}

impl From<ChannelCategory> for CategoryDto {
    fn from(category: ChannelCategory) -> Self {
        Self {
            id: category.id.to_string(),
            name: category.name,
            position: category.position,
            created_at: category.created_at,
            parent_id: category.parent_id.map(|id| id.to_string()),
        }
    }
}

impl From<CategoryWriteError> for ApiError {
    fn from(err: CategoryWriteError) -> Self {
        match err {
            CategoryWriteError::NotFound => ApiError::NotFound("category not found"),
            CategoryWriteError::UnknownParent => {
                ApiError::BadRequest("parent_id must name a category that exists")
            }
            CategoryWriteError::SelfParent => {
                ApiError::BadRequest("a category cannot be its own parent")
            }
            CategoryWriteError::ParentIsNested => {
                ApiError::Conflict("a sub-category cannot hold sub-categories of its own")
            }
            CategoryWriteError::HasChildren => {
                ApiError::Conflict("a category that holds sub-categories cannot move under another")
            }
            CategoryWriteError::Internal(e) => e.into(),
        }
    }
}

#[derive(Deserialize)]
struct CreateCategoryRequest {
    /// Client-generated UUIDv7 that makes the create idempotent on retry.
    /// Absent means the server mints one and this is always a fresh create.
    id: Option<String>,
    name: String,
    /// The top-level category to create this under; absent or null for a top-level one.
    #[serde(default)]
    parent_id: Option<String>,
}

#[derive(Deserialize)]
struct UpdateCategoryRequest {
    /// Absent leaves the name unchanged, the same "at least one, absent
    /// means untouched" convention `channels::UpdateChannelRequest` uses.
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    position: Option<i64>,
    /// Absent leaves the placement alone, null moves it to the top level.
    #[serde(default, deserialize_with = "super::space::present")]
    parent_id: Option<Option<String>>,
}

/// The categories the caller can see, in tree order: all for a channel manager, else those holding
/// a channel they can view plus each such one's parent, never a sub-category below (decision 0120).
async fn list(
    AuthedLimited(ctx): AuthedLimited<AUTHED_READ>,
    State(state): State<AppState>,
) -> Result<Json<Vec<CategoryDto>>, ApiError> {
    let categories = state.store.list_categories().await?;
    let manages = state
        .store
        .base_permissions(ctx.user_id)
        .await?
        .contains(Permissions::MANAGE_CHANNELS);
    let holding = match manages {
        true => HashSet::new(),
        false => state
            .store
            .visible_channels(ctx.user_id)
            .await?
            .into_iter()
            .filter_map(|channel| channel.category_id)
            .collect(),
    };
    let visible = visible_categories(&categories, manages, &holding);
    Ok(Json(
        categories
            .into_iter()
            .filter(|c| visible.contains(&c.id))
            .map(CategoryDto::from)
            .collect(),
    ))
}

/// The category closure: every category for a channel manager, else those in `holding` plus their parents.
pub(super) fn visible_categories(
    categories: &[ChannelCategory],
    manages: bool,
    holding: &HashSet<ChannelCategoryId>,
) -> HashSet<ChannelCategoryId> {
    if manages {
        return categories.iter().map(|c| c.id).collect();
    }
    let parents = categories
        .iter()
        .filter(|c| holding.contains(&c.id))
        .filter_map(|c| c.parent_id);
    parents.chain(holding.iter().copied()).collect()
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
    let id = parse_category_id(req.id.as_deref())?.unwrap_or_else(ChannelCategoryId::generate);
    let parent = parse_category_id(req.parent_id.as_deref())?;

    let created = state
        .store
        .create_category_with_id(id, name, parent)
        .await?;
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
    let parent = req
        .parent_id
        .as_ref()
        .map(|raw| parse_category_id(raw.as_deref()))
        .transpose()?;
    if name.is_none() && req.position.is_none() && parent.is_none() {
        return Err(ApiError::BadRequest("nothing to update"));
    }

    let update = CategoryUpdate {
        name,
        position: req.position,
        parent,
    };
    let category = state.store.update_category(category_id, update).await?;
    state.hub.publish(Event::CategoryChanged);
    Ok(Json(category.into()))
}

/// Soft-deletes a category, moving its contents up one level. Idempotent on one
/// already deleted, the same convention `deleteChannel` follows.
async fn delete(
    Authed(ctx): Authed,
    parts: Parts,
    Path(category_id): Path<String>,
    State(state): State<AppState>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    require_manage_channels(&state, ctx.user_id).await?;
    let category_id = ChannelCategoryId(parse_uuid(&category_id)?);

    if state.store.delete_category(category_id).await? {
        state.hub.publish(Event::CategoryChanged);
    }
    Ok(StatusCode::NO_CONTENT)
}

fn parse_category_id(raw: Option<&str>) -> Result<Option<ChannelCategoryId>, ApiError> {
    raw.map(|raw| parse_uuid(raw).map(ChannelCategoryId))
        .transpose()
}

pub(super) async fn require_manage_channels(
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
