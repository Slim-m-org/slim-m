// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The caller's own hold-music choice, so it follows them across devices.

use axum::Router;
use axum::extract::{DefaultBodyLimit, State};
use axum::http::request::Parts;
use axum::routing::get;
use serde::{Deserialize, Serialize};

use super::AppState;
use super::error::ApiError;
use super::extract::{AUTHED_READ, Authed, AuthedLimited, Json, enforce};
use crate::ratelimit::Class;

const BODY_LIMIT: usize = 1024;

/// The hold-music routes, mounted by [`super::router`].
pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/me/hold-music", get(get_choice).put(set_choice))
        .layer(DefaultBodyLimit::max(BODY_LIMIT))
}

#[derive(Serialize)]
struct HoldMusicDto {
    /// `null` until the member has chosen.
    enabled: Option<bool>,
}

#[derive(Deserialize)]
struct SetHoldMusicRequest {
    enabled: bool,
}

async fn get_choice(
    AuthedLimited(ctx): AuthedLimited<AUTHED_READ>,
    State(state): State<AppState>,
) -> Result<Json<HoldMusicDto>, ApiError> {
    let enabled = state
        .store
        .hold_music(ctx.user_id)
        .await?
        .ok_or(ApiError::Unauthorized)?;
    Ok(Json(HoldMusicDto { enabled }))
}

async fn set_choice(
    Authed(ctx): Authed,
    parts: Parts,
    State(state): State<AppState>,
    Json(req): Json<SetHoldMusicRequest>,
) -> Result<Json<HoldMusicDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    if !state.store.set_hold_music(ctx.user_id, req.enabled).await? {
        return Err(ApiError::Unauthorized);
    }
    Ok(Json(HoldMusicDto {
        enabled: Some(req.enabled),
    }))
}
