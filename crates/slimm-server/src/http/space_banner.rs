// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The space banner: one image an admin sets for the invite landing card.
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

/// Larger than an avatar: a banner is a wide picture.
const BANNER_MAX_BYTES: u64 = 4 * 1024 * 1024;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route(
            "/space/banner",
            get(get_banner).post(upload_banner).delete(delete_banner),
        )
        .route("/invites/{code}/banner", get(get_invite_banner))
        .layer(DefaultBodyLimit::max(BANNER_MAX_BYTES as usize))
}

#[derive(serde::Serialize)]
struct BannerDto {
    banner_updated_at: i64,
}

async fn upload_banner(
    Authed(ctx): Authed,
    parts: Parts,
    State(state): State<AppState>,
    Bytes(body): Bytes,
) -> Result<Json<BannerDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Upload)?;
    require_manage_server(&state, ctx.user_id).await?;
    if body.is_empty() {
        return Err(ApiError::BadRequest("banner is empty"));
    }
    if body.len() as u64 > BANNER_MAX_BYTES {
        return Err(ApiError::BadRequest("banner is too large"));
    }
    if !media::sniff_content_type(&body).is_some_and(media::is_inline) {
        return Err(ApiError::BadRequest("unsupported banner type"));
    }
    state
        .media
        .write_space_banner(body.to_vec())
        .await
        .map_err(|err| {
            tracing::error!(error = %err, "failed to write the space banner");
            ApiError::Internal
        })?;
    let at = now_ms();
    state.store.set_space_banner(Some(at)).await?;
    Ok(Json(BannerDto {
        banner_updated_at: at,
    }))
}

async fn delete_banner(
    Authed(ctx): Authed,
    parts: Parts,
    State(state): State<AppState>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    require_manage_server(&state, ctx.user_id).await?;
    state.store.set_space_banner(None).await?;
    if let Err(err) = state.media.delete_space_banner().await {
        tracing::warn!(error = %err, "failed to delete a cleared space banner file");
    }
    Ok(StatusCode::NO_CONTENT)
}

async fn get_banner(
    AuthedLimited(_ctx): AuthedLimited<ASSET>,
    State(state): State<AppState>,
) -> Result<Response, ApiError> {
    banner_response(&state).await
}

/// Served only for a usable code, so the banner is no more public than the
/// invite check that already discloses the deployment's name.
async fn get_invite_banner(
    _limited: RateLimited<INVITE_CHECK>,
    Path(code): Path<String>,
    State(state): State<AppState>,
) -> Result<Response, ApiError> {
    match state.store.check_invite(&code).await? {
        InviteCheck::Usable(_) => banner_response(&state).await,
        InviteCheck::Unusable => Err(ApiError::NotFound("no banner")),
    }
}

async fn banner_response(state: &AppState) -> Result<Response, ApiError> {
    if state
        .store
        .space_landing()
        .await?
        .banner_updated_at
        .is_none()
    {
        return Err(ApiError::NotFound("no banner"));
    }
    let bytes = state.media.read_space_banner().await.map_err(|err| {
        tracing::error!(error = %err, "failed to read the space banner");
        ApiError::Internal
    })?;
    let content_type = media::sniff_content_type(&bytes).ok_or_else(|| {
        tracing::error!("stored banner bytes no longer match the upload allowlist");
        ApiError::Internal
    })?;
    Ok(serve(bytes, content_type, "banner"))
}
