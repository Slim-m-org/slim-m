// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Debug logs members send to the admins: any member submits one, holders of
//! `MANAGE_SERVER` list, read and delete them.
//!
//! Submitting charges `Class::Upload`: a log is up to [`MAX_LOG_BYTES`] of disk per request.

use axum::Router;
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::StatusCode;
use axum::http::request::Parts;
use axum::routing::get;
use serde::{Deserialize, Serialize};

use super::AppState;
use super::device_client_info::validate_client_info;
use super::error::ApiError;
use super::extract::{Authed, Json, enforce, require_manage_server};
use crate::ratelimit::Class;
use crate::store::{DebugLogFull, DebugLogSummary, NewDebugLog};

/// The log text a submission may carry.
const MAX_LOG_BYTES: usize = 1024 * 1024;
/// Room for JSON escaping around [`MAX_LOG_BYTES`], so the cap is the clear error and not a bare 413.
const BODY_LIMIT: usize = MAX_LOG_BYTES * 2 + 4096;
const MAX_NOTE_CHARS: usize = 500;
const MAX_LABEL_CHARS: usize = 64;
const PAGE_DEFAULT: i64 = 50;
const PAGE_MAX: i64 = 200;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/debug-logs", get(list).post(submit))
        .route("/debug-logs/{id}", get(read).delete(remove))
        .layer(DefaultBodyLimit::max(BODY_LIMIT))
}

#[derive(Deserialize)]
struct SubmitRequest {
    log: String,
    #[serde(default)]
    note: String,
    app_version: String,
    platform: String,
}

#[derive(Serialize)]
struct SubmittedDto {
    id: i64,
    created_at: i64,
}

#[derive(Serialize)]
struct DebugLogDto {
    id: i64,
    user_id: String,
    username: String,
    display_name: String,
    note: String,
    app_version: String,
    platform: String,
    size_bytes: i64,
    created_at: i64,
}

#[derive(Serialize)]
struct DebugLogTextDto {
    #[serde(flatten)]
    summary: DebugLogDto,
    log: String,
}

impl From<DebugLogSummary> for DebugLogDto {
    fn from(row: DebugLogSummary) -> Self {
        Self {
            id: row.id,
            user_id: row.user_id.to_string(),
            username: row.username,
            display_name: row.display_name,
            note: row.note,
            app_version: row.app_version,
            platform: row.platform,
            size_bytes: row.size_bytes,
            created_at: row.created_at,
        }
    }
}

impl From<DebugLogFull> for DebugLogTextDto {
    fn from(row: DebugLogFull) -> Self {
        Self {
            summary: row.summary.into(),
            log: row.log,
        }
    }
}

#[derive(Deserialize)]
struct ListQuery {
    before: Option<i64>,
    limit: Option<i64>,
}

fn label(value: &str, what: &'static str) -> Result<String, ApiError> {
    validate_client_info(value, MAX_LABEL_CHARS)?.ok_or(ApiError::BadRequest(what))
}

async fn submit(
    Authed(ctx): Authed,
    parts: Parts,
    State(state): State<AppState>,
    Json(req): Json<SubmitRequest>,
) -> Result<(StatusCode, Json<SubmittedDto>), ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Upload)?;
    if req.log.trim().is_empty() {
        return Err(ApiError::BadRequest("the debug log is empty"));
    }
    if req.log.len() > MAX_LOG_BYTES {
        return Err(ApiError::BadRequest("the debug log is over 1 MiB"));
    }
    let note = req.note.trim();
    if note.chars().count() > MAX_NOTE_CHARS {
        return Err(ApiError::BadRequest("the note is over 500 characters"));
    }
    let app_version = label(&req.app_version, "app_version must be 1 to 64 characters")?;
    let platform = label(&req.platform, "platform must be 1 to 64 characters")?;
    let new = NewDebugLog {
        note,
        app_version: &app_version,
        platform: &platform,
        log: &req.log,
    };
    let (id, created_at) = state.store.submit_debug_log(ctx.user_id, &new).await?;
    Ok((StatusCode::CREATED, Json(SubmittedDto { id, created_at })))
}

async fn list(
    Authed(ctx): Authed,
    parts: Parts,
    State(state): State<AppState>,
    axum::extract::Query(query): axum::extract::Query<ListQuery>,
) -> Result<Json<Vec<DebugLogDto>>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::AuthedRead)?;
    require_manage_server(&state, ctx.user_id).await?;
    let limit = query.limit.unwrap_or(PAGE_DEFAULT).clamp(1, PAGE_MAX);
    let rows = state.store.list_debug_logs(query.before, limit).await?;
    Ok(Json(rows.into_iter().map(Into::into).collect()))
}

async fn read(
    Authed(ctx): Authed,
    parts: Parts,
    State(state): State<AppState>,
    Path(id): Path<i64>,
) -> Result<Json<DebugLogTextDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::AuthedRead)?;
    require_manage_server(&state, ctx.user_id).await?;
    let row = state
        .store
        .debug_log(id)
        .await?
        .ok_or(ApiError::NotFound("debug log not found"))?;
    Ok(Json(row.into()))
}

async fn remove(
    Authed(ctx): Authed,
    parts: Parts,
    State(state): State<AppState>,
    Path(id): Path<i64>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    require_manage_server(&state, ctx.user_id).await?;
    if !state.store.delete_debug_log(id).await? {
        return Err(ApiError::NotFound("debug log not found"));
    }
    Ok(StatusCode::NO_CONTENT)
}
