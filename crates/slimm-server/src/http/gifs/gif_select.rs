// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Downloading a selected GIF as a local attachment.

use axum::extract::State;
use axum::http::StatusCode;
use serde::Deserialize;
use sha2::{Digest, Sha256};

use super::filename::{extension_for, slug_filename};
use super::require_attach_files;
use crate::http::AppState;
use crate::http::error::ApiError;
use crate::http::extract::{AuthedLimited, GIF, Json};
use crate::http::message_dto::AttachmentDto;
use crate::http::storage_room::room_for;
use crate::media;
use crate::store::AttachmentSummary;

#[derive(Deserialize)]
pub(super) struct SelectRequest {
    pub(super) id: String,
    #[serde(default)]
    pub(super) channel_id: Option<String>,
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
    let (bytes, title) = state.gifs.download_full(&req.id).await?;
    if bytes.len() as u64 > state.media.max_attachment_bytes() {
        return Err(ApiError::BadRequest("gif is too large to attach"));
    }
    room_for(&state, bytes.len() as i64).await?;
    // Unsniffable is the provider's doing, never the caller's own token.
    let content_type = media::sniff_content_type(&bytes).ok_or(ApiError::Unavailable)?;
    // Named after the provider's title (slugged, falling back to "gif"), so a saved GIF is findable later rather than a wall of identical "gif.gif".
    let filename = format!("{}.{}", slug_filename(&title), extension_for(content_type));

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
        .store_attachment(&sha256, size, content_type, &filename, Some(ctx.user_id))
        .await?;
    drop(placing);
    Ok((
        StatusCode::CREATED,
        Json(AttachmentDto::from(AttachmentSummary {
            id: hex_id,
            filename,
            content_type: content_type.to_owned(),
            size,
            spoiler: false,
            original: None,
        })),
    ))
}
