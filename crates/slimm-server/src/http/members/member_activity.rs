// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `GET /members/activity`: when each member last posted, so the role editor
//! can offer the most active members first.
//!
//! Gated on MANAGE_ROLES, the permission of the only screen that asks, and
//! charged [`Class::Write`] like `/space/analytics`, since it aggregates over
//! messages. Only channels the caller can view count, with the threads under
//! them, so a private channel never reveals that somebody is active in it.

use axum::Router;
use axum::extract::{DefaultBodyLimit, State};
use axum::http::request::Parts;
use axum::routing::get;
use serde::Serialize;

use super::super::AppState;
use super::super::error::ApiError;
use super::super::extract::{Authed, Json, enforce, require_manage_roles};
use crate::ratelimit::Class;

const BODY_LIMIT: usize = 256;

/// The member activity route, mounted by [`super::super::router`].
pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/members/activity", get(list_activity))
        .layer(DefaultBodyLimit::max(BODY_LIMIT))
}

#[derive(Serialize)]
struct MemberActivityDto {
    user_id: String,
    last_posted_at: i64,
}

/// Members with no live message in a channel the caller can view are absent.
async fn list_activity(
    Authed(ctx): Authed,
    parts: Parts,
    State(state): State<AppState>,
) -> Result<Json<Vec<MemberActivityDto>>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    require_manage_roles(&state, ctx.user_id).await?;
    let channels: Vec<_> = state
        .store
        .visible_channels(ctx.user_id)
        .await?
        .into_iter()
        .map(|channel| channel.id)
        .collect();
    let latest = state.store.last_posted_in(&channels).await?;
    Ok(Json(
        latest
            .into_iter()
            .map(|(user_id, last_posted_at)| MemberActivityDto {
                user_id: user_id.to_string(),
                last_posted_at,
            })
            .collect(),
    ))
}
