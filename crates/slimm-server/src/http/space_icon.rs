// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The space icon: a small square image shown beside the space's name.
//!
//! Members and admins read it signed in; someone holding a usable invite code
//! reads it before they have an account. Nothing else reaches it.

use axum::Router;
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::StatusCode;
use axum::http::request::Parts;
use axum::response::Response;
use axum::routing::get;

use super::AppState;
use super::attachments::serve;
use super::error::ApiError;
use super::extract::{
    ASSET, Authed, AuthedLimited, Bytes, INVITE_CHECK, Json, RateLimited, enforce,
    require_manage_server,
};
use crate::media;
use crate::ratelimit::Class;
use crate::store::{InviteCheck, now_ms};

/// The client crops to a square and downsizes first, so this is generous.
const ICON_MAX_BYTES: u64 = 512 * 1024;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route(
            "/space/icon",
            get(get_icon).post(upload_icon).delete(delete_icon),
        )
        .route("/invites/{code}/icon", get(get_invite_icon))
        .layer(DefaultBodyLimit::max(ICON_MAX_BYTES as usize))
}

#[derive(serde::Serialize)]
struct IconDto {
    icon_updated_at: i64,
}

async fn upload_icon(
    Authed(ctx): Authed,
    parts: Parts,
    State(state): State<AppState>,
    Bytes(body): Bytes,
) -> Result<Json<IconDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Upload)?;
    require_manage_server(&state, ctx.user_id).await?;
    if body.is_empty() {
        return Err(ApiError::BadRequest("icon is empty"));
    }
    if body.len() as u64 > ICON_MAX_BYTES {
        return Err(ApiError::BadRequest("icon is too large"));
    }
    super::still_picture::require_still_picture(
        &body,
        &super::still_picture::Refusals {
            unsupported: "unsupported icon type",
            animated: "icon must be a still image",
            too_large: "icon must be at most 4096 pixels on a side",
        },
    )?;
    state
        .media
        .write_space_icon(body.to_vec())
        .await
        .map_err(|err| {
            tracing::error!(error = %err, "failed to write the space icon");
            ApiError::Internal
        })?;
    let at = now_ms();
    state.store.set_space_icon(Some(at)).await?;
    Ok(Json(IconDto {
        icon_updated_at: at,
    }))
}

async fn delete_icon(
    Authed(ctx): Authed,
    parts: Parts,
    State(state): State<AppState>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    require_manage_server(&state, ctx.user_id).await?;
    state.store.set_space_icon(None).await?;
    if let Err(err) = state.media.delete_space_icon().await {
        tracing::warn!(error = %err, "failed to delete a cleared space icon file");
    }
    Ok(StatusCode::NO_CONTENT)
}

async fn get_icon(
    AuthedLimited(_ctx): AuthedLimited<ASSET>,
    State(state): State<AppState>,
) -> Result<Response, ApiError> {
    icon_response(&state).await
}

/// Served only for a usable code, so the icon is no more public than the
/// invite check that already discloses the deployment's name.
async fn get_invite_icon(
    _limited: RateLimited<INVITE_CHECK>,
    Path(code): Path<String>,
    State(state): State<AppState>,
) -> Result<Response, ApiError> {
    match state.store.check_invite(&code).await? {
        InviteCheck::Usable(_) => icon_response(&state).await,
        InviteCheck::Unusable => Err(ApiError::NotFound("no icon")),
    }
}

async fn icon_response(state: &AppState) -> Result<Response, ApiError> {
    if state.store.space_landing().await?.icon_updated_at.is_none() {
        return Err(ApiError::NotFound("no icon"));
    }
    let bytes = state.media.read_space_icon().await.map_err(|err| {
        tracing::error!(error = %err, "failed to read the space icon");
        ApiError::Internal
    })?;
    let content_type = media::sniff_content_type(&bytes).ok_or_else(|| {
        tracing::error!("stored icon bytes no longer match the upload allowlist");
        ApiError::Internal
    })?;
    Ok(serve(bytes, content_type, "icon"))
}
