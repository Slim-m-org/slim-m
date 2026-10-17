// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Giving another member or bot a space-local display name (decision 0055).
//!
//! Gated on KICK_MEMBERS and the same no-escalation rule as a timeout, since
//! this is the same tier of act: changing how somebody else appears. The
//! account's own `display_name` is never written, so a clear restores it.

use axum::Router;
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::StatusCode;
use axum::http::request::Parts;
use axum::routing::put;
use serde::Deserialize;

use super::super::AppState;
use super::super::auth::validate_label;
use super::super::error::ApiError;
use super::super::extract::{Authed, Json, enforce};
use super::super::messages::parse_uuid;
use super::authorize;
use crate::hub::Event;
use crate::ids::UserId;
use crate::permissions::Permissions;
use crate::ratelimit::Class;

const BODY_LIMIT: usize = 4 * 1024;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route(
            "/members/{user_id}/nickname",
            put(set_nickname).delete(clear_nickname),
        )
        .layer(DefaultBodyLimit::max(BODY_LIMIT))
}

#[derive(Deserialize)]
struct NicknameRequest {
    nickname: String,
}

/// Sets the nickname, replacing any already on this member. Requires KICK_MEMBERS.
async fn set_nickname(
    Authed(ctx): Authed,
    parts: Parts,
    Path(user_id): Path<String>,
    State(state): State<AppState>,
    Json(req): Json<NicknameRequest>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let target = UserId(parse_uuid(&user_id)?);
    authorize(&state, ctx.user_id, target, Permissions::KICK_MEMBERS).await?;

    let nickname = req.nickname.trim();
    validate_label(nickname, "nickname must be 1 to 64 characters")?;
    match state
        .store
        .set_nickname(target, nickname, ctx.user_id)
        .await?
    {
        None => return Err(ApiError::NotFound("no such member")),
        Some(true) => state.hub.publish(Event::ProfileChanged(target)),
        Some(false) => {}
    }
    Ok(StatusCode::NO_CONTENT)
}

/// Clears the nickname. Requires KICK_MEMBERS. Idempotent.
async fn clear_nickname(
    Authed(ctx): Authed,
    parts: Parts,
    Path(user_id): Path<String>,
    State(state): State<AppState>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let target = UserId(parse_uuid(&user_id)?);
    authorize(&state, ctx.user_id, target, Permissions::KICK_MEMBERS).await?;

    if state.store.clear_nickname(target, ctx.user_id).await? {
        state.hub.publish(Event::ProfileChanged(target));
    }
    Ok(StatusCode::NO_CONTENT)
}
