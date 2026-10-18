// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `GET`/`PATCH /space/media-compression`: the admin's choice to shrink photos
//! on upload, which file types it covers, and what it does with their metadata.

use axum::Router;
use axum::extract::{DefaultBodyLimit, State};
use axum::http::request::Parts;
use axum::routing::get;
use serde::{Deserialize, Serialize};

use super::AppState;
use super::error::ApiError;
use super::extract::{Authed, Json, enforce, require_manage_server};
use crate::media::compress::{self, ExtensionError, Metadata};
use crate::ratelimit::Class;
use crate::store::{MediaCompression, MediaCompressionUpdate};

const BODY_LIMIT: usize = 2048;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/space/media-compression", get(read).patch(update))
        .layer(DefaultBodyLimit::max(BODY_LIMIT))
}

#[derive(Serialize)]
struct MediaCompressionDto {
    enabled: bool,
    /// The extensions in force, the defaults when none were chosen.
    extensions: Vec<String>,
    default_extensions: Vec<String>,
    /// Every extension a list may name.
    supported_extensions: Vec<&'static str>,
    metadata: &'static str,
    keep_original: bool,
}

impl From<MediaCompression> for MediaCompressionDto {
    fn from(settings: MediaCompression) -> Self {
        Self {
            enabled: settings.enabled,
            extensions: settings.extensions,
            default_extensions: crate::store::default_extensions(),
            supported_extensions: compress::supported_extensions(),
            metadata: settings.metadata.as_str(),
            keep_original: settings.keep_original,
        }
    }
}

#[derive(Deserialize)]
struct MediaCompressionPatch {
    enabled: Option<bool>,
    extensions: Option<Vec<String>>,
    metadata: Option<String>,
    keep_original: Option<bool>,
}

async fn read(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
) -> Result<Json<MediaCompressionDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::AuthedRead)?;
    require_manage_server(&state, ctx.user_id).await?;
    Ok(Json(state.store.media_compression().await?.into()))
}

async fn update(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    Json(body): Json<MediaCompressionPatch>,
) -> Result<Json<MediaCompressionDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    require_manage_server(&state, ctx.user_id).await?;
    let extensions = body
        .extensions
        .map(|raw| compress::normalize_extensions(&raw).map_err(extension_error))
        .transpose()?;
    let metadata = body
        .metadata
        .map(|raw| Metadata::parse(&raw).ok_or(ApiError::BadRequest("unknown metadata mode")))
        .transpose()?;
    let settings = state
        .store
        .update_media_compression(MediaCompressionUpdate {
            enabled: body.enabled,
            extensions,
            metadata,
            keep_original: body.keep_original,
        })
        .await?;
    Ok(Json(settings.into()))
}

fn extension_error(err: ExtensionError) -> ApiError {
    ApiError::BadRequest(match err {
        ExtensionError::Malformed(_) => "extension is malformed",
        ExtensionError::Unsupported(_) => "extension is not supported",
        ExtensionError::TooMany => "too many extensions",
    })
}
