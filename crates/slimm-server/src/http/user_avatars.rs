// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The avatar routes, split out of `users.rs` when that file reached its
//! 500-line ceiling.
//!
//! They sit apart cleanly because they are the only handlers here that touch
//! bytes on disk rather than rows: each one pairs a `media` write or delete
//! with the profile row that points at it, and the ordering between those two
//! is the whole subtlety of this file.

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
use crate::media;
use crate::ratelimit::Class;

/// Uploads (or replaces) the caller's avatar. Deliberately not an attachment:
/// one mutable image per user, keyed by user id rather than content hash, and
/// replaced wholesale rather than accumulated - see migration 0013.
///
/// The file is written before the database row is updated, so a crash
/// between the two steps leaves the old row pointing at bytes that were just
/// overwritten (self-heals on the next successful upload) rather than a row
/// that promises an avatar no file backs.
///
/// An avatar is always a still picture of bounded size: a PDF is a valid
/// attachment and not a valid avatar, and neither is an animated GIF. The
/// content type itself is not stored here; [`get_avatar`] re-sniffs it from disk.
pub(super) async fn upload_avatar(
    Authed(ctx): Authed,
    parts: Parts,
    State(state): State<AppState>,
    Bytes(body): Bytes,
) -> Result<Json<UserDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Upload)?;

    if body.is_empty() {
        return Err(ApiError::BadRequest("avatar is empty"));
    }
    if body.len() as u64 > AVATAR_MAX_BYTES {
        return Err(ApiError::BadRequest("avatar is too large"));
    }
    super::still_picture::require_still_picture(
        &body,
        &super::still_picture::Refusals {
            unsupported: "unsupported avatar type",
            animated: "avatar must be a still image",
            too_large: "avatar must be at most 4096 pixels on a side",
        },
    )?;

    let user_id = ctx.user_id.to_string();
    state
        .media
        .write_avatar(&user_id, body.to_vec())
        .await
        .map_err(|err| {
            tracing::error!(error = %err, "failed to write an uploaded avatar");
            ApiError::Internal
        })?;

    let user = state
        .store
        .set_avatar_updated(ctx.user_id)
        .await?
        .ok_or(ApiError::Unauthorized)?;
    // Announced like a rename: a client's avatar cache is keyed by `avatar_updated_at`, so with no event every other client draws the old picture until it restarts.
    state.hub.publish(Event::ProfileChanged(ctx.user_id));
    Ok(Json(to_dto(&state.store, user).await?))
}

/// Removes the caller's avatar.
pub(super) async fn delete_avatar(
    Authed(ctx): Authed,
    parts: Parts,
    State(state): State<AppState>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    state.store.clear_avatar(ctx.user_id).await?;
    if let Err(err) = state.media.delete_avatar(&ctx.user_id.to_string()).await {
        tracing::warn!(error = %err, "failed to delete a cleared avatar file");
    }
    // Announced like an upload: removing a picture is as much a profile change as setting one.
    state.hub.publish(Event::ProfileChanged(ctx.user_id));
    Ok(StatusCode::NO_CONTENT)
}

/// Fetches a user's avatar bytes. Any authenticated caller may fetch any
/// live user's avatar: it is a public profile picture, gated the same way
/// the rest of a `UserProfile` is (authentication only, no channel
/// permission), not a message attachment.
pub(super) async fn get_avatar(
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
    if user.avatar_updated_at.is_none() {
        return Err(ApiError::NotFound("user has no avatar"));
    }

    let bytes = state
        .media
        .read_avatar(&user_id.to_string())
        .await
        .map_err(|err| {
            tracing::error!(error = %err, "failed to read a stored avatar");
            ApiError::Internal
        })?;
    // Re-sniffed from disk: the bytes cannot disagree with themselves.
    let content_type = media::sniff_content_type(&bytes).ok_or_else(|| {
        tracing::error!("stored avatar bytes no longer match the upload allowlist");
        ApiError::Internal
    })?;
    Ok(serve(bytes, content_type, "avatar"))
}
