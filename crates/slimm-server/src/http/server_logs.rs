// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `GET /space/server-logs`: the newest server log lines, for an admin to download (decision 0129).

use std::path::PathBuf;

use axum::extract::State;
use axum::http::request::Parts;
use axum::routing::get;
use axum::{Extension, Router};
use serde::Serialize;

use super::AppState;
use super::error::ApiError;
use super::extract::{Authed, Json, enforce, require_manage_server};
use crate::ratelimit::Class;

/// The most log text one download carries; older lines stay in the files on the data volume.
const MAX_DOWNLOAD_BYTES: u64 = 16 * 1024 * 1024;

/// Where the log files are, handed to the router as an `Extension`; None when they are not written.
#[derive(Clone, Debug)]
pub struct ServerLogsDir(pub Option<PathBuf>);

pub fn routes() -> Router<AppState> {
    Router::new().route("/space/server-logs", get(download))
}

#[derive(Serialize)]
struct ServerLogsDto {
    /// Oldest line first.
    log: String,
    /// Older lines exist than fit in one download.
    truncated: bool,
    /// False when this server writes no log files, so there is nothing to download.
    files_enabled: bool,
}

async fn download(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    dir: Option<Extension<ServerLogsDir>>,
) -> Result<Json<ServerLogsDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::AuthedRead)?;
    require_manage_server(&state, ctx.user_id).await?;
    let Some(dir) = dir.and_then(|Extension(ServerLogsDir(dir))| dir) else {
        return Ok(Json(ServerLogsDto {
            log: String::new(),
            truncated: false,
            files_enabled: false,
        }));
    };
    let recent = tokio::task::spawn_blocking(move || {
        if let Some(logging) = crate::logging::installed() {
            logging.flush();
        }
        crate::logging::recent(&dir, MAX_DOWNLOAD_BYTES)
    })
    .await
    .map_err(anyhow::Error::from)?
    .map_err(anyhow::Error::from)?;
    Ok(Json(ServerLogsDto {
        log: recent.text,
        truncated: recent.truncated,
        files_enabled: true,
    }))
}
