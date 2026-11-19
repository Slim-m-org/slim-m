// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The caller's own mute of a whole category: every channel under it, and under its sub-categories,
//! stays quiet unless the channel has its own override. Enforced in push fan-out (`store/category_mutes.rs`).

use axum::Router;
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::StatusCode;
use axum::http::request::Parts;
use axum::routing::{get, put};
use serde::Serialize;

use super::AppState;
use super::category_sight::CategorySight;
use super::error::ApiError;
use super::extract::{AUTHED_READ, Authed, AuthedLimited, Json, enforce};
use super::messages::parse_uuid;
use crate::hub::Event;
use crate::ids::{ChannelCategoryId, UserId};
use crate::ratelimit::Class;

/// No route here takes a body.
const BODY_LIMIT: usize = 1024;

/// The category-mute routes, mounted by [`super::router`].
pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/notification-preferences/categories", get(list))
        .route(
            "/notification-preferences/categories/{category_id}",
            put(mute).delete(unmute),
        )
        .layer(DefaultBodyLimit::max(BODY_LIMIT))
}

#[derive(Serialize)]
struct CategoryMuteDto {
    category_id: String,
}

/// Every live category the caller has muted.
async fn list(
    AuthedLimited(ctx): AuthedLimited<AUTHED_READ>,
    State(state): State<AppState>,
) -> Result<Json<Vec<CategoryMuteDto>>, ApiError> {
    let muted = state.store.list_category_mutes(ctx.user_id).await?;
    Ok(Json(
        muted
            .into_iter()
            .map(|id| CategoryMuteDto {
                category_id: id.to_string(),
            })
            .collect(),
    ))
}

/// Mutes a category the caller can see; one they cannot answers 404, the same as one that does not exist.
async fn mute(
    Authed(ctx): Authed,
    parts: Parts,
    Path(category_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<CategoryMuteDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let category_id = ChannelCategoryId(parse_uuid(&category_id)?);
    let sight = CategorySight::of(&state, ctx.user_id).await?;
    if !sight.listed.contains(&category_id) {
        return Err(ApiError::NotFound("category not found"));
    }
    if state.store.mute_category(ctx.user_id, category_id).await? {
        announce(&state, ctx.user_id, category_id, true);
    }
    Ok(Json(CategoryMuteDto {
        category_id: category_id.to_string(),
    }))
}

/// Idempotent and unchecked, like clearing a channel override: it only touches the caller's own row.
async fn unmute(
    Authed(ctx): Authed,
    parts: Parts,
    Path(category_id): Path<String>,
    State(state): State<AppState>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let category_id = ChannelCategoryId(parse_uuid(&category_id)?);
    if state
        .store
        .unmute_category(ctx.user_id, category_id)
        .await?
    {
        announce(&state, ctx.user_id, category_id, false);
    }
    Ok(StatusCode::NO_CONTENT)
}

fn announce(state: &AppState, user_id: UserId, category_id: ChannelCategoryId, muted: bool) {
    state.hub.publish(Event::CategoryMuteChanged {
        user_id,
        category_id,
        muted,
    });
}
