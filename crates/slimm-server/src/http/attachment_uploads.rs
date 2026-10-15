// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Resumable attachment uploads: open a session, send ordered parts, then
//! complete it into an ordinary attachment. Exists because a reverse proxy
//! caps one request's body (Cloudflare at 100 MB), so a single-request
//! upload of a large file fails before slim-m sees it.
//!
//! The checks `POST /attachments` runs (ATTACH_FILES, the size ceiling, the
//! deployment's room, the type sniff) run here too: the first three when the
//! session opens and again on completion, the sniff on completion, over the
//! same leading bytes. Storage is [`crate::media::Uploads`].

use axum::Router;
use axum::body::Body;
use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::routing::{get, post};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use super::AppState;
use super::attachments::{effective_attachment_max, room_for, sniffable};
use super::error::ApiError;
use super::extract::{AUTHED_READ, AuthedLimited, Json, Query, UPLOAD, WRITE};
use super::message_dto::AttachmentDto;
use crate::ids::UserId;
use crate::media::{
    self, AppendError, MAX_OPEN_SESSIONS_PER_USER, UPLOAD_PART_MAX_BYTES, UPLOAD_SESSION_TTL,
    UploadMeta,
};
use crate::permissions::Permissions;
use crate::store::{AttachmentSummary, now_ms};

/// Mounted beside `POST /attachments`, outside the total-time request timeout.
pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/attachments/uploads", post(create))
        .route(
            "/attachments/uploads/{upload_id}",
            get(status).put(append).delete(discard),
        )
        .route("/attachments/uploads/{upload_id}/complete", post(complete))
}

#[derive(Deserialize)]
struct CreateRequest {
    filename: Option<String>,
    size: u64,
}

#[derive(Serialize)]
struct UploadSessionDto {
    id: String,
    size: u64,
    /// Bytes received so far; the next part starts here.
    offset: u64,
    part_max_bytes: u64,
    expires_at: i64,
}

impl UploadSessionDto {
    fn new(id: Uuid, meta: &UploadMeta, offset: u64) -> Self {
        Self {
            id: id.to_string(),
            size: meta.size,
            offset,
            part_max_bytes: UPLOAD_PART_MAX_BYTES,
            expires_at: meta.created_at + UPLOAD_SESSION_TTL.as_millis() as i64,
        }
    }
}

#[derive(Deserialize)]
struct AppendParams {
    offset: u64,
}

async fn may_attach(state: &AppState, user_id: UserId) -> Result<(), ApiError> {
    let base = state.store.base_permissions(user_id).await?;
    if base.contains(Permissions::ATTACH_FILES) {
        Ok(())
    } else {
        Err(ApiError::Forbidden)
    }
}

/// Charged to the upload budget once per file; the parts ride the write budget.
async fn create(
    AuthedLimited(ctx): AuthedLimited<UPLOAD>,
    State(state): State<AppState>,
    Json(req): Json<CreateRequest>,
) -> Result<(StatusCode, Json<UploadSessionDto>), ApiError> {
    may_attach(&state, ctx.user_id).await?;
    if req.size == 0 {
        return Err(ApiError::BadRequest("attachment is empty"));
    }
    if req.size > effective_attachment_max(&state).await? {
        return Err(ApiError::PayloadTooLarge);
    }
    room_for(&state, i64::try_from(req.size).unwrap_or(i64::MAX)).await?;
    let uploads = state.media.uploads();
    if uploads
        .open_sessions_for(ctx.user_id.0.to_string())
        .await
        .map_err(io_error)?
        >= MAX_OPEN_SESSIONS_PER_USER
    {
        return Err(ApiError::TooManyRequests);
    }
    let meta = UploadMeta {
        user_id: ctx.user_id.0.to_string(),
        filename: media::sanitize_filename(req.filename.as_deref().unwrap_or("file")),
        size: req.size,
        created_at: now_ms(),
    };
    let id = uploads.create(meta.clone()).await.map_err(io_error)?;
    Ok((
        StatusCode::CREATED,
        Json(UploadSessionDto::new(id, &meta, 0)),
    ))
}

/// Where to resume after a dropped part.
async fn status(
    AuthedLimited(ctx): AuthedLimited<AUTHED_READ>,
    Path(upload_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<UploadSessionDto>, ApiError> {
    let (id, meta, offset) = owned_session(&state, ctx.user_id, &upload_id).await?;
    Ok(Json(UploadSessionDto::new(id, &meta, offset)))
}

/// A part that does not start where the data ends is a 409, so a client
/// re-reads the offset rather than writing a byte twice.
async fn append(
    AuthedLimited(ctx): AuthedLimited<WRITE>,
    Path(upload_id): Path<String>,
    Query(params): Query<AppendParams>,
    State(state): State<AppState>,
    body: Body,
) -> Result<Json<UploadSessionDto>, ApiError> {
    let (id, meta, _) = owned_session(&state, ctx.user_id, &upload_id).await?;
    let offset = state
        .media
        .uploads()
        .append(id, params.offset, body.into_data_stream())
        .await
        .map_err(|err| match err {
            AppendError::Missing => ApiError::NotFound("upload not found"),
            AppendError::Busy => ApiError::Conflict("another part is still uploading"),
            AppendError::OffsetMismatch(_) => {
                ApiError::Conflict("part does not start at the upload's offset")
            }
            AppendError::TooLarge => ApiError::PayloadTooLarge,
            AppendError::Body => ApiError::BadRequest("upload stream ended early"),
            AppendError::Io(err) => io_error(err),
        })?;
    // The type is decided by the leading bytes alone, so refuse as soon as they are in, not after the last part.
    let sniffable_len = meta.size.min(512);
    if params.offset < sniffable_len && offset >= sniffable_len {
        let uploads = state.media.uploads();
        let prefix = uploads.leading_bytes(id).await.map_err(io_error)?;
        if media::sniff_content_type(sniffable(&prefix)).is_none() {
            uploads.discard(id).await.ok();
            return Err(ApiError::BadRequest("unsupported attachment type"));
        }
    }
    Ok(Json(UploadSessionDto::new(id, &meta, offset)))
}

/// Hashes the assembled file and stores it as an attachment, exactly as
/// `POST /attachments` would have.
async fn complete(
    AuthedLimited(ctx): AuthedLimited<WRITE>,
    Path(upload_id): Path<String>,
    State(state): State<AppState>,
) -> Result<(StatusCode, Json<AttachmentDto>), ApiError> {
    let (id, meta, offset) = owned_session(&state, ctx.user_id, &upload_id).await?;
    may_attach(&state, ctx.user_id).await?;
    if offset != meta.size {
        return Err(ApiError::Conflict("upload is not complete"));
    }
    let uploads = state.media.uploads();
    let finished = uploads
        .finish(id)
        .await
        .map_err(|err| match err {
            AppendError::Busy => ApiError::Conflict("another part is still uploading"),
            AppendError::Io(err) => io_error(err),
            _ => ApiError::Internal,
        })?
        .ok_or(ApiError::Conflict("upload is not complete"))?;
    let Some(content_type) = media::sniff_content_type(sniffable(&finished.sniff_prefix)) else {
        uploads.discard(id).await.ok();
        return Err(ApiError::BadRequest("unsupported attachment type"));
    };
    let size = i64::try_from(finished.size).unwrap_or(i64::MAX);
    if let Err(err) = room_for(&state, size).await {
        uploads.discard(id).await.ok();
        return Err(err);
    }
    // Bytes before the metadata row, the same order `POST /attachments` keeps.
    let placing = state.media.blob_guard().await;
    uploads
        .place(id, &finished.hex_id)
        .await
        .map_err(io_error)?;
    let sha256 =
        media::from_hex(&finished.hex_id).expect("a hex id from sha256 is well-formed hex");
    state
        .store
        .store_attachment(
            &sha256,
            size,
            content_type,
            &meta.filename,
            Some(ctx.user_id),
        )
        .await?;
    drop(placing);
    Ok((
        StatusCode::CREATED,
        Json(AttachmentDto::from(AttachmentSummary {
            id: finished.hex_id,
            filename: meta.filename,
            content_type: content_type.to_owned(),
            size,
            spoiler: false,
        })),
    ))
}

async fn discard(
    AuthedLimited(ctx): AuthedLimited<WRITE>,
    Path(upload_id): Path<String>,
    State(state): State<AppState>,
) -> Result<StatusCode, ApiError> {
    let (id, _, _) = owned_session(&state, ctx.user_id, &upload_id).await?;
    state.media.uploads().discard(id).await.map_err(io_error)?;
    Ok(StatusCode::NO_CONTENT)
}

/// Someone else's session reads as missing, the same collapse attachments use.
async fn owned_session(
    state: &AppState,
    user_id: UserId,
    upload_id: &str,
) -> Result<(Uuid, UploadMeta, u64), ApiError> {
    let not_found = ApiError::NotFound("upload not found");
    let Ok(id) = Uuid::parse_str(upload_id) else {
        return Err(not_found);
    };
    match state.media.uploads().status(id).await.map_err(io_error)? {
        Some((meta, offset)) if meta.user_id == user_id.0.to_string() => Ok((id, meta, offset)),
        _ => Err(not_found),
    }
}

fn io_error(err: std::io::Error) -> ApiError {
    tracing::error!(error = %err, "upload session storage failed");
    ApiError::Internal
}
