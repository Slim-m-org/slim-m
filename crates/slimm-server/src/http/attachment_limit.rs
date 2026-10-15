// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The admin's per-attachment size limit: `GET`/`PATCH /space/attachment-limit`.
//!
//! The operator's `SLIMM_ATTACHMENT_MAX_BYTES` stays the hard ceiling; an
//! admin may only lower it, so a Space setting can never accept a file the
//! host was not sized for. Every member reads the limit in force from
//! `/version`'s `max_attachment_bytes`.

use axum::Router;
use axum::extract::{DefaultBodyLimit, State};
use axum::http::request::Parts;
use axum::routing::get;
use serde::{Deserialize, Serialize};

use super::AppState;
use super::error::ApiError;
use super::extract::{Authed, Json, enforce, require_manage_server};
use crate::ratelimit::Class;

const BODY_LIMIT: usize = 256;

/// The smallest limit an admin may set, so a typo cannot stop every upload.
pub const MIN_ATTACHMENT_LIMIT_BYTES: u64 = 1024 * 1024;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route(
            "/space/attachment-limit",
            get(read_limit).patch(update_limit),
        )
        .layer(DefaultBodyLimit::max(BODY_LIMIT))
}

#[derive(Serialize)]
struct AttachmentLimitDto {
    /// The admin's limit in bytes, or 0 for none.
    max_bytes: u64,
    /// The operator's ceiling, which `max_bytes` may not exceed.
    server_max_bytes: u64,
}

#[derive(Deserialize)]
struct AttachmentLimitUpdate {
    max_bytes: u64,
}

async fn read_limit(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
) -> Result<Json<AttachmentLimitDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::AuthedRead)?;
    require_manage_server(&state, ctx.user_id).await?;
    Ok(Json(AttachmentLimitDto {
        max_bytes: state.store.attachment_max_bytes().await?,
        server_max_bytes: state.media.max_attachment_bytes(),
    }))
}

/// Out of range is refused, not clamped, the rule the other Space limits follow.
async fn update_limit(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    Json(body): Json<AttachmentLimitUpdate>,
) -> Result<Json<AttachmentLimitDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    require_manage_server(&state, ctx.user_id).await?;
    let server_max_bytes = state.media.max_attachment_bytes();
    let settable = (MIN_ATTACHMENT_LIMIT_BYTES..=server_max_bytes).contains(&body.max_bytes);
    if body.max_bytes != 0 && !settable {
        return Err(ApiError::BadRequest("max_bytes out of range"));
    }
    state.store.set_attachment_max_bytes(body.max_bytes).await?;
    Ok(Json(AttachmentLimitDto {
        max_bytes: body.max_bytes,
        server_max_bytes,
    }))
}
