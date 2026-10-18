// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `GET`/`PATCH /space/link-previews`: the admin switch for link previews.

use axum::Router;
use axum::extract::State;
use axum::http::request::Parts;
use axum::routing::get;
use serde::{Deserialize, Serialize};

use super::AppState;
use super::error::ApiError;
use super::extract::{Authed, Json, enforce, require_manage_server};
use crate::ratelimit::Class;

pub fn routes() -> Router<AppState> {
    Router::new().route("/space/link-previews", get(read).patch(update))
}

#[derive(Serialize, Deserialize)]
struct LinkPreviewsDto {
    /// Whether this space unfurls pasted links into preview cards.
    enabled: bool,
}

async fn read(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
) -> Result<Json<LinkPreviewsDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::AuthedRead)?;
    require_manage_server(&state, ctx.user_id).await?;
    Ok(Json(LinkPreviewsDto {
        enabled: state.link_previews.is_enabled(),
    }))
}

async fn update(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    Json(body): Json<LinkPreviewsDto>,
) -> Result<Json<LinkPreviewsDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    require_manage_server(&state, ctx.user_id).await?;
    state.store.set_link_previews_override(body.enabled).await?;
    state.link_previews.set_override(Some(body.enabled));
    Ok(Json(LinkPreviewsDto {
        enabled: state.link_previews.is_enabled(),
    }))
}
