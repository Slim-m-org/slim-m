// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Downloading a selected GIF as a local attachment.

use axum::extract::State;
use axum::http::StatusCode;
use serde::Deserialize;
use sha2::{Digest, Sha256};

use super::MAX_DOWNLOAD_BYTES;
use super::filename::{extension_for, is_gif_content_type, slug_filename};
use super::require_attach_files;
use crate::http::AppState;
use crate::http::attachments::effective_attachment_max;
use crate::http::error::ApiError;
use crate::http::extract::{AuthedLimited, GIF, Json, user_limit_key};
use crate::http::message_dto::AttachmentDto;
use crate::http::storage_room::reserve_room;
use crate::media;
use crate::ratelimit::Class;
use crate::store::AttachmentSummary;

#[derive(Deserialize)]
pub(super) struct SelectRequest {
    pub(super) id: String,
    #[serde(default)]
    pub(super) channel_id: Option<String>,
    /// For a screen stamp, which takes a rendition small enough to animate (decision 0121).
    #[serde(default)]
    pub(super) for_stamp: bool,
}

/// Downloads the full-resolution image through this server and stores it
/// exactly the way `uploadAttachment` stores a client-supplied body -
/// content-addressed, sniffed rather than trusted, checked against both size
/// ceilings - so what a send later references is an ordinary attachment with
/// no lingering dependency on the provider or the token that named it.
pub(super) async fn select(
    AuthedLimited(ctx): AuthedLimited<GIF>,
    State(state): State<AppState>,
    Json(req): Json<SelectRequest>,
) -> Result<(StatusCode, Json<AttachmentDto>), ApiError> {
    require_attach_files(&state, ctx.user_id, req.channel_id.as_deref()).await?;
    charge_select(&state, ctx.user_id)?;
    let max_bytes = download_cap(&state).await?;
    let (bytes, title) = if req.for_stamp {
        state.gifs.download_for_stamp(&req.id, max_bytes).await?
    } else {
        state.gifs.download_full(&req.id, max_bytes).await?
    };
    let attachment = store_gif(&state, ctx.user_id, bytes, &title).await?;
    Ok((StatusCode::CREATED, Json(attachment)))
}

/// A select stores bytes like an upload does, so it is charged against the upload budget too.
pub(crate) fn charge_select(state: &AppState, user_id: crate::ids::UserId) -> Result<(), ApiError> {
    state
        .limiter
        .admit(Class::Upload, &user_limit_key(user_id))
        .map_err(ApiError::from)
}

/// The most a select may download: the provider sanity bound, lowered to the admin's attachment cap.
pub(crate) async fn download_cap(state: &AppState) -> Result<u64, ApiError> {
    Ok(MAX_DOWNLOAD_BYTES.min(effective_attachment_max(state).await?))
}

/// Stores downloaded GIF bytes as an ordinary attachment owned by `user_id`.
pub(crate) async fn store_gif(
    state: &AppState,
    user_id: crate::ids::UserId,
    bytes: Vec<u8>,
    title: &str,
) -> Result<AttachmentDto, ApiError> {
    if bytes.len() as u64 > effective_attachment_max(state).await? {
        return Err(ApiError::BadRequest("gif is too large to attach"));
    }
    // Anything but a GIF, webp or mp4 is the provider's doing, never the caller's own token.
    let content_type = media::sniff_content_type(&bytes)
        .filter(|content_type| is_gif_content_type(content_type))
        .ok_or(ApiError::Unavailable)?;
    let reservation = reserve_room(state, bytes.len() as i64, None).await?;
    // Named after the provider's title (slugged, falling back to "gif"), so a saved GIF is findable later rather than a wall of identical "gif.gif".
    let filename = format!("{}.{}", slug_filename(title), extension_for(content_type));

    let sha256 = Sha256::digest(&bytes).to_vec();
    let hex_id = media::to_hex(&sha256);
    let size = bytes.len() as i64;

    let placing = state.media.blob_guard().await;
    state
        .media
        .write_attachment(&hex_id, bytes)
        .await
        .map_err(|err| {
            tracing::error!(error = %err, "failed to write a selected gif's bytes");
            ApiError::Internal
        })?;
    state
        .store
        .store_attachment(&sha256, size, content_type, &filename, Some(user_id))
        .await?;
    drop(placing);
    drop(reservation);
    Ok(AttachmentDto::from(AttachmentSummary {
        id: hex_id,
        filename,
        content_type: content_type.to_owned(),
        size,
        spoiler: false,
        voice: None,
        transcript: None,
        original: None,
    }))
}
