// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Channel category routes (decisions 0006 and 0120). Every mutation needs
//! deployment-level MANAGE_CHANNELS, checked before any id in the body is read,
//! and answers a category the caller is not listed, or may not manage, as one that does not exist.

use axum::Router;
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::StatusCode;
use axum::http::request::Parts;
use axum::routing::{get, patch};
use serde::{Deserialize, Serialize};

use super::AppState;
use super::category_sight::CategorySight;
use super::error::ApiError;
use super::extract::{AUTHED_READ, Authed, AuthedLimited, Json, WRITE, enforce};
use super::hidden_chars::{draws_nothing, is_hidden_char};
use super::messages::parse_uuid;
use crate::hub::Event;
use crate::ids::ChannelCategoryId;
use crate::permissions::Permissions;
use crate::ratelimit::Class;
use crate::store::{CategoryUpdate, CategoryWriteError, ChannelCategory};

const CATEGORY_BODY_LIMIT: usize = 4 * 1024;
/// The highest position a client may set; sibling positions only order a short list.
const CATEGORY_POSITION_MAX: i64 = 100_000;
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
    /// Whether the caller may rename, delete or move it; absent where no caller's view is meant.
    #[serde(skip_serializing_if = "Option::is_none")]
    manageable: Option<bool>,
    /// Whether the caller may file a channel or sub-category under it; absent like `manageable`.
    #[serde(skip_serializing_if = "Option::is_none")]
    fileable: Option<bool>,
}

impl CategoryDto {
    pub(super) fn with_reach(self, manageable: bool, fileable: bool) -> Self {
        Self {
            manageable: Some(manageable),
            fileable: Some(fileable),
            ..self
        }
    }
}

impl From<ChannelCategory> for CategoryDto {
    fn from(category: ChannelCategory) -> Self {
        Self {
            id: category.id.to_string(),
            name: category.name,
            position: category.position,
            created_at: category.created_at,
            parent_id: category.parent_id.map(|id| id.to_string()),
            manageable: None,
            fileable: None,
        }
    }
}

const CATEGORY_NOT_FOUND: ApiError = ApiError::NotFound("category not found");
const UNKNOWN_PARENT: ApiError = ApiError::BadRequest("parent_id must name a category that exists");
const ID_IN_USE: ApiError = ApiError::Conflict("that category id is already in use");

impl From<CategoryWriteError> for ApiError {
    fn from(err: CategoryWriteError) -> Self {
        match err {
            CategoryWriteError::NotFound => CATEGORY_NOT_FOUND,
            CategoryWriteError::UnknownParent => UNKNOWN_PARENT,
            CategoryWriteError::SelfParent => {
                ApiError::BadRequest("a category cannot be its own parent")
            }
            CategoryWriteError::ParentIsNested => {
                ApiError::Conflict("a sub-category cannot hold sub-categories of its own")
            }
            CategoryWriteError::Deleted => ID_IN_USE,
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

/// The categories the caller can see, in tree order ([`CategorySight`]).
async fn list(
    AuthedLimited(ctx): AuthedLimited<AUTHED_READ>,
    State(state): State<AppState>,
) -> Result<Json<Vec<CategoryDto>>, ApiError> {
    let sight = CategorySight::of(&state, ctx.user_id).await?;
    Ok(Json(sight.listed_dtos()))
}

/// `id` unless the caller may not file anything under it, which answers `missing`, what an id
/// naming nothing gets: what is filed there copies its rows and would vanish from them.
fn unless_unfileable(
    sight: &CategorySight,
    id: Option<ChannelCategoryId>,
    missing: ApiError,
) -> Result<Option<ChannelCategoryId>, ApiError> {
    match id {
        Some(id) if sight.shuts(id) => Err(missing),
        id => Ok(id),
    }
}

async fn create(
    AuthedLimited(ctx): AuthedLimited<WRITE>,
    State(state): State<AppState>,
    Json(req): Json<CreateCategoryRequest>,
) -> Result<Json<CategoryDto>, ApiError> {
    require_manage_channels(&state, ctx.user_id).await?;

    let name = validate_category_name(&req.name)?;
    let id = parse_category_id(req.id.as_deref())?.unwrap_or_else(ChannelCategoryId::generate);
    let parent = parse_category_id(req.parent_id.as_deref())?;
    // A retry answers the stored row, which must not hand a hidden category's name to someone else.
    let sight = CategorySight::of(&state, ctx.user_id).await?;
    if sight.closes(id) {
        return Err(ID_IN_USE);
    }
    let parent = unless_unfileable(&sight, parent, UNKNOWN_PARENT)?;

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
    AuthedLimited(ctx): AuthedLimited<WRITE>,
    Path(category_id): Path<String>,
    State(state): State<AppState>,
    Json(req): Json<UpdateCategoryRequest>,
) -> Result<Json<CategoryDto>, ApiError> {
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
    if req
        .position
        .is_some_and(|position| !(0..=CATEGORY_POSITION_MAX).contains(&position))
    {
        return Err(ApiError::BadRequest("position is out of range"));
    }
    // Where the store would refuse a missing category, then a missing parent, in that order.
    let sight = CategorySight::of(&state, ctx.user_id).await?;
    // A rename carries nothing along, so only a move needs the category to be theirs to move.
    let moves = parent.is_some() || req.position.is_some();
    if sight.shuts(category_id) || moves && sight.closes(category_id) {
        return Err(CATEGORY_NOT_FOUND);
    }
    let parent = parent
        .map(|parent| unless_unfileable(&sight, parent, UNKNOWN_PARENT))
        .transpose()?;

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
    // One the caller may not manage answers as one already gone does.
    let closed = CategorySight::of(&state, ctx.user_id)
        .await?
        .closes(category_id);
    if !closed && state.store.delete_category(category_id).await? {
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
    if draws_nothing(trimmed) {
        return Err(ApiError::BadRequest("name must not be blank"));
    }
    Ok(trimmed)
}
