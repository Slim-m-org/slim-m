// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The Space theme store (decision 0106).
//!
//! Any member publishes; the author or a `MANAGE_SERVER` holder removes;
//! only `MANAGE_SERVER` picks the Space default. Applying a theme is local to
//! the device and calls nothing here.

use axum::Router;
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::StatusCode;
use axum::http::request::Parts;
use axum::response::Response;
use axum::routing::{get, put};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::AppState;
use super::attachments::serve;
use super::error::ApiError;
use super::extract::{
    ASSET, AUTHED_READ, Authed, AuthedLimited, Json, enforce, require_manage_server,
};
use crate::ids::{ThemeId, UserId};
use crate::ratelimit::Class;
use crate::space_theme::{self, MAX_PICTURE_BYTES};
use crate::store::{PublishError, SpaceTheme};

/// The picture rides base64 inside the JSON file, so the body is a third
/// larger than the bytes it carries.
const BODY_LIMIT_BYTES: usize = (MAX_PICTURE_BYTES / 3) * 4 + 65_536;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/space/themes", get(list).post(publish))
        .route_layer(DefaultBodyLimit::max(BODY_LIMIT_BYTES))
        .route("/space/themes/{theme_id}", axum::routing::delete(remove))
        .route("/space/themes/{theme_id}/picture", get(picture))
        .route("/space/default-theme", put(set_default))
}

#[derive(Debug, Serialize)]
pub struct SpaceThemeDto {
    pub id: String,
    pub name: String,
    pub author_id: Option<String>,
    pub author_name: String,
    pub created_at: i64,
    pub has_picture: bool,
    /// The theme document, without picture bytes.
    pub theme: Value,
}

#[derive(Debug, Serialize)]
pub struct SpaceThemeList {
    pub themes: Vec<SpaceThemeDto>,
    pub default_theme_id: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct SetDefaultRequest {
    pub theme_id: Option<String>,
}

fn dto(theme: SpaceTheme) -> SpaceThemeDto {
    SpaceThemeDto {
        id: theme.id.to_string(),
        name: theme.name,
        author_id: theme.author_id.map(|id| id.to_string()),
        author_name: theme.author_name,
        created_at: theme.created_at,
        has_picture: theme.has_picture,
        theme: serde_json::from_str(&theme.doc).unwrap_or(Value::Null),
    }
}

fn parse_id(raw: &str) -> Result<ThemeId, ApiError> {
    raw.parse::<uuid::Uuid>()
        .map(ThemeId)
        .map_err(|_| ApiError::BadRequest("invalid theme id"))
}

async fn list(
    AuthedLimited(_ctx): AuthedLimited<AUTHED_READ>,
    State(state): State<AppState>,
) -> Result<Json<SpaceThemeList>, ApiError> {
    let themes = state.store.list_space_themes().await?;
    let default = state.store.default_space_theme().await?;
    Ok(Json(SpaceThemeList {
        themes: themes.into_iter().map(dto).collect(),
        default_theme_id: default.map(|id| id.to_string()),
    }))
}

async fn publish(
    Authed(ctx): Authed,
    parts: Parts,
    State(state): State<AppState>,
    Json(body): Json<Value>,
) -> Result<(StatusCode, Json<SpaceThemeDto>), ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let valid = space_theme::validate(&body)
        .map_err(|problems| ApiError::BadRequestDetail(problems.join("; ")))?;
    let author_name = state
        .store
        .user_profile(ctx.user_id)
        .await?
        .map(|user| user.display_name)
        .unwrap_or_default();
    let picture = valid
        .picture
        .as_ref()
        .map(|(bytes, kind)| (bytes.as_slice(), *kind));
    let created = state
        .store
        .publish_space_theme(ctx.user_id, &author_name, &valid.name, &valid.doc, picture)
        .await?
        .map_err(|PublishError::Full| ApiError::Conflict("this Space is at its theme limit"))?;
    Ok((StatusCode::CREATED, Json(dto(created))))
}

async fn remove(
    Authed(ctx): Authed,
    parts: Parts,
    Path(theme_id): Path<String>,
    State(state): State<AppState>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let id = parse_id(&theme_id)?;
    let theme = state
        .store
        .space_theme(id)
        .await?
        .ok_or(ApiError::NotFound("theme not found"))?;
    if theme.author_id != Some(UserId(ctx.user_id.0)) {
        require_manage_server(&state, ctx.user_id).await?;
    }
    state.store.delete_space_theme(id).await?;
    Ok(StatusCode::NO_CONTENT)
}

async fn picture(
    AuthedLimited(_ctx): AuthedLimited<ASSET>,
    Path(theme_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Response, ApiError> {
    let id = parse_id(&theme_id)?;
    let picture = state
        .store
        .space_theme_picture(id)
        .await?
        .ok_or(ApiError::NotFound("theme picture not found"))?;
    Ok(serve(
        picture.bytes,
        &picture.content_type,
        "theme-backdrop",
    ))
}

async fn set_default(
    Authed(ctx): Authed,
    parts: Parts,
    State(state): State<AppState>,
    Json(body): Json<SetDefaultRequest>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    require_manage_server(&state, ctx.user_id).await?;
    let id = body.theme_id.as_deref().map(parse_id).transpose()?;
    if let Some(id) = id
        && state.store.space_theme(id).await?.is_none()
    {
        return Err(ApiError::NotFound("theme not found"));
    }
    state.store.set_default_space_theme(id).await?;
    Ok(StatusCode::NO_CONTENT)
}
