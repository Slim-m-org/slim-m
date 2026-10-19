// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The profile banner routes: an image, or a gif, drawn behind a profile card
//! instead of the profile colour. Same upload path, size and pixel limits as an
//! avatar; decision 0074.

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::http::request::Parts;
use axum::response::Response;

use super::AppState;
use super::attachments::serve;
use super::error::ApiError;
use super::extract::{ASSET, Authed, AuthedLimited, Bytes, Json, enforce};
use super::messages::parse_uuid;
use super::users::{AVATAR_MAX_BYTES, UserDto, to_dto};
use crate::hub::Event;
use crate::ids::UserId;
use crate::media::{self, ImageProblem, Motion};
use crate::ratelimit::Class;

/// Uploads (or replaces) the caller's banner. The file is written before the row, as for an avatar.
pub(super) async fn upload_banner(
    Authed(ctx): Authed,
    parts: Parts,
    State(state): State<AppState>,
    Bytes(body): Bytes,
) -> Result<Json<UserDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Upload)?;
    if body.is_empty() {
        return Err(ApiError::BadRequest("banner is empty"));
    }
    if body.len() as u64 > AVATAR_MAX_BYTES {
        return Err(ApiError::BadRequest("banner is too large"));
    }
    media::check_image(
        &body,
        Motion::AnimatedAllowed,
        media::MAX_PROFILE_IMAGE_SIDE,
    )
    .map_err(|problem| {
        ApiError::BadRequest(match problem {
            ImageProblem::Unsupported | ImageProblem::Animated => "unsupported banner type",
            ImageProblem::TooLarge => "banner must be at most 4096 pixels on a side",
        })
    })?;

    let user_id = ctx.user_id.to_string();
    state
        .media
        .write_user_banner(&user_id, body.to_vec())
        .await
        .map_err(|err| {
            tracing::error!(error = %err, "failed to write an uploaded banner");
            ApiError::Internal
        })?;
    let user = state
        .store
        .set_banner_updated(ctx.user_id)
        .await?
        .ok_or(ApiError::Unauthorized)?;
    state.hub.publish(Event::ProfileChanged(ctx.user_id));
    Ok(Json(to_dto(&state.store, user).await?))
}

/// Removes the caller's banner, so the profile colour shows again.
pub(super) async fn delete_banner(
    Authed(ctx): Authed,
    parts: Parts,
    State(state): State<AppState>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    state.store.clear_banner(ctx.user_id).await?;
    if let Err(err) = state
        .media
        .delete_user_banner(&ctx.user_id.to_string())
        .await
    {
        tracing::warn!(error = %err, "failed to delete a cleared banner file");
    }
    state.hub.publish(Event::ProfileChanged(ctx.user_id));
    Ok(StatusCode::NO_CONTENT)
}

/// Fetches a user's banner bytes; any authenticated caller may, like an avatar.
pub(super) async fn get_banner(
    AuthedLimited(_ctx): AuthedLimited<ASSET>,
    Path(user_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Response, ApiError> {
    let user_id = UserId(parse_uuid(&user_id)?);
    let user = state
        .store
        .user_profile(user_id)
        .await?
        .ok_or(ApiError::NotFound("user not found"))?;
    if user.banner_updated_at.is_none() {
        return Err(ApiError::NotFound("user has no banner"));
    }
    let bytes = state
        .media
        .read_user_banner(&user_id.to_string())
        .await
        .map_err(|err| {
            tracing::error!(error = %err, "failed to read a stored banner");
            ApiError::Internal
        })?;
    let content_type = media::sniff_content_type(&bytes).ok_or_else(|| {
        tracing::error!("stored banner bytes no longer match the upload allowlist");
        ApiError::Internal
    })?;
    Ok(serve(bytes, content_type, "banner"))
}
