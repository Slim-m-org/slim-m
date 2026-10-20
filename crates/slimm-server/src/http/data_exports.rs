// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Starting, watching and downloading data exports (decision 0084).
//!
//! A member exports only their own data. A space export needs ADMINISTRATOR,
//! the one bit that already reads every channel, because MANAGE_SERVER does not
//! and the archive holds every channel's messages. Both ask for the caller's
//! password, since an archive is a copy of everything the session can see.

use axum::Router;
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::request::Parts;
use axum::http::{HeaderMap, HeaderValue, StatusCode, header};
use axum::response::Response;
use axum::routing::{get, post};
use serde::Serialize;

use super::AppState;
use super::attachment_range::serve_ranged;
use super::error::ApiError;
use super::extract::{
    AUTHED_READ, Authed, AuthedLimited, Bytes, Json, PASSWORD, enforce, require_base_permission,
};
use super::messages::parse_uuid;
use super::reauth::require_admin_password;
use crate::export;
use crate::ids::{ExportId, UserId};
use crate::permissions::Permissions;
use crate::ratelimit::Class;
use crate::store::{CreateExportError, DataExport, ExportKind, ExportStatus, now_ms};

/// The password body is tiny; anything bigger is refused before it is read.
const BODY_LIMIT: usize = 4 * 1024;
/// Most jobs listed at once, newest first.
const LIST_LIMIT: i64 = 10;
const ARCHIVE_TYPE: &str = "application/x-tar";

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/exports", get(list))
        .route("/exports/member", post(start_member))
        .route("/exports/space", post(start_space))
        .route("/exports/{export_id}", get(show).delete(remove))
        .route("/exports/{export_id}/download", get(download))
        .layer(DefaultBodyLimit::max(BODY_LIMIT))
}

#[derive(Serialize)]
struct ExportDto {
    id: String,
    kind: &'static str,
    /// queued, running, ready, failed or expired.
    status: &'static str,
    /// Items written so far and expected in all; both zero until counted.
    processed: i64,
    total: i64,
    size_bytes: Option<i64>,
    error: Option<String>,
    created_at: i64,
    finished_at: Option<i64>,
    expires_at: Option<i64>,
}

impl From<DataExport> for ExportDto {
    fn from(job: DataExport) -> Self {
        let lapsed = job.status == ExportStatus::Ready && !job.is_downloadable(now_ms());
        let status = if lapsed {
            ExportStatus::Expired
        } else {
            job.status
        };
        Self {
            id: job.id.to_string(),
            kind: job.kind.as_str(),
            status: status.as_str(),
            processed: job.processed,
            total: job.total,
            size_bytes: job.size_bytes,
            error: job.error,
            created_at: job.created_at,
            finished_at: job.finished_at,
            expires_at: job.expires_at,
        }
    }
}

/// Queues an export of the caller's own data.
async fn start_member(
    AuthedLimited(ctx): AuthedLimited<PASSWORD>,
    State(state): State<AppState>,
    Bytes(body): Bytes,
) -> Result<(StatusCode, Json<ExportDto>), ApiError> {
    require_admin_password(&state, ctx.user_id, &body).await?;
    start(&state, ctx.user_id, ExportKind::Member).await
}

/// Queues an export of the whole space. ADMINISTRATOR only, and audited.
async fn start_space(
    AuthedLimited(ctx): AuthedLimited<PASSWORD>,
    State(state): State<AppState>,
    Bytes(body): Bytes,
) -> Result<(StatusCode, Json<ExportDto>), ApiError> {
    require_base_permission(&state, ctx.user_id, Permissions::ADMINISTRATOR).await?;
    require_admin_password(&state, ctx.user_id, &body).await?;
    start(&state, ctx.user_id, ExportKind::Space).await
}

async fn start(
    state: &AppState,
    user_id: UserId,
    kind: ExportKind,
) -> Result<(StatusCode, Json<ExportDto>), ApiError> {
    let job = match state.store.create_data_export(user_id, kind).await {
        Ok(job) => job,
        Err(CreateExportError::Busy) => {
            return Err(ApiError::Conflict("an export is already being prepared"));
        }
        Err(CreateExportError::TooSoon(retry_after_seconds)) => {
            return Err(ApiError::RateLimited {
                retry_after_seconds,
            });
        }
        Err(CreateExportError::Internal(err)) => return Err(err.into()),
    };
    export::spawn(
        state.store.clone(),
        state.media.clone(),
        export::Job {
            id: job.id,
            user_id,
            kind,
        },
    );
    Ok((StatusCode::ACCEPTED, Json(job.into())))
}

/// The caller's own exports, newest first.
async fn list(
    AuthedLimited(ctx): AuthedLimited<AUTHED_READ>,
    State(state): State<AppState>,
) -> Result<Json<Vec<ExportDto>>, ApiError> {
    let jobs = state
        .store
        .data_exports_for(ctx.user_id, LIST_LIMIT)
        .await?;
    Ok(Json(jobs.into_iter().map(Into::into).collect()))
}

/// One of the caller's exports. Someone else's reads as missing.
async fn owned(state: &AppState, user_id: UserId, export_id: &str) -> Result<DataExport, ApiError> {
    let id = ExportId(parse_uuid(export_id)?);
    state
        .store
        .data_export(id)
        .await?
        .filter(|job| job.user_id == user_id)
        .ok_or(ApiError::NotFound("export not found"))
}

async fn show(
    AuthedLimited(ctx): AuthedLimited<AUTHED_READ>,
    Path(export_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<ExportDto>, ApiError> {
    Ok(Json(owned(&state, ctx.user_id, &export_id).await?.into()))
}

/// Streams a finished archive with range support, so a large one can resume.
///
/// A space archive is re-checked against ADMINISTRATOR now, not when it was
/// requested, and each download of one is audited.
async fn download(
    Authed(ctx): Authed,
    parts: Parts,
    Path(export_id): Path<String>,
    headers: HeaderMap,
    State(state): State<AppState>,
) -> Result<Response, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Asset)?;
    let job = owned(&state, ctx.user_id, &export_id).await?;
    if !job.is_downloadable(now_ms()) {
        return Err(ApiError::NotFound(
            "this export is not available to download",
        ));
    }
    if job.kind == ExportKind::Space {
        require_base_permission(&state, ctx.user_id, Permissions::ADMINISTRATOR).await?;
        let detail = serde_json::json!({ "size_bytes": job.size_bytes }).to_string();
        state
            .store
            .record_admin_change(
                ctx.user_id,
                "space.export_download",
                Some(&export_id),
                &detail,
            )
            .await?;
    }
    let (file, len) = state
        .media
        .open_export(&job.id.to_string())
        .await
        .map_err(|err| {
            tracing::error!(%err, "a ready export has no file");
            ApiError::NotFound("this export is not available to download")
        })?;
    let range = headers.get(header::RANGE).and_then(|v| v.to_str().ok());
    let filename = format!(
        "slimm-{}-export-{}.tar",
        job.kind.as_str(),
        job.created_at / 1000
    );
    let mut response = serve_ranged(file, len, range, ARCHIVE_TYPE, &filename).await?;
    response.headers_mut().insert(
        header::CACHE_CONTROL,
        HeaderValue::from_static("private, no-store"),
    );
    Ok(response)
}

/// Deletes an export and its file now. A running one is cancelled by its row going.
async fn remove(
    Authed(ctx): Authed,
    parts: Parts,
    Path(export_id): Path<String>,
    State(state): State<AppState>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let job = owned(&state, ctx.user_id, &export_id).await?;
    state.store.delete_data_export(job.id).await?;
    if let Err(err) = state.media.remove_export(&job.id.to_string()).await {
        tracing::warn!(%err, "could not delete an export's files");
    }
    Ok(StatusCode::NO_CONTENT)
}
