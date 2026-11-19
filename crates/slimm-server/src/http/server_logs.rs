// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `GET /space/server-logs`: the newest server log lines as plain text, for an
//! admin to download (decision 0129).
//!
//! Streamed file by file from a plan made up front, so a download holds one
//! read buffer rather than the whole text, and one download runs at a time.

use std::io;
use std::path::PathBuf;

use axum::body::{Body, Bytes};
use axum::extract::State;
use axum::http::request::Parts;
use axum::http::{HeaderValue, header};
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use axum::{Extension, Router};
use futures_util::{StreamExt, stream};
use tokio::io::{AsyncReadExt, AsyncSeekExt};
use tokio::sync::Semaphore;
use tokio_util::io::ReaderStream;

use super::AppState;
use super::error::ApiError;
use super::extract::{Authed, enforce, require_manage_server};
use crate::logging::{Segment, plan_recent};
use crate::ratelimit::Class;

/// The most log text one download carries; older lines stay in the files on the data volume.
const MAX_DOWNLOAD_BYTES: u64 = 16 * 1024 * 1024;
const STREAM_CHUNK: usize = 64 * 1024;
/// The first line of a download that does not reach back to the oldest file.
pub const OLDER_LINES_NOTE: &str = "[older lines are in the log files on the server]\n";

static DOWNLOADS: Semaphore = Semaphore::const_new(1);

/// Where the log files are, handed to the router as an `Extension`; None when they are not written.
#[derive(Clone, Debug)]
pub struct ServerLogsDir(pub Option<PathBuf>);

pub fn routes() -> Router<AppState> {
    Router::new().route("/space/server-logs", get(download))
}

async fn download(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    dir: Option<Extension<ServerLogsDir>>,
) -> Result<Response, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Upload)?;
    require_manage_server(&state, ctx.user_id).await?;
    let Some(dir) = dir.and_then(|Extension(ServerLogsDir(dir))| dir) else {
        return Err(ApiError::NotConfigured("this server keeps no log files"));
    };
    let permit = DOWNLOADS
        .try_acquire()
        .map_err(|_| ApiError::TooManyRequests)?;
    let plan = tokio::task::spawn_blocking(move || {
        if let Some(logging) = crate::logging::installed() {
            logging.flush();
        }
        plan_recent(&dir, MAX_DOWNLOAD_BYTES, crate::logging::today())
    })
    .await
    .map_err(anyhow::Error::from)?
    .map_err(anyhow::Error::from)?;
    let note = plan
        .truncated
        .then(|| Ok(Bytes::from_static(OLDER_LINES_NOTE.as_bytes())));
    let body = stream::iter(note)
        .chain(stream::iter(plan.segments).flat_map(segment_stream))
        .map(move |chunk| {
            let _held = &permit;
            chunk
        });
    let mut response = Body::from_stream(body).into_response();
    response.headers_mut().insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("text/plain; charset=utf-8"),
    );
    Ok(response)
}

/// One planned stretch, never past its planned length; a file deleted since streams nothing.
fn segment_stream(segment: Segment) -> stream::BoxStream<'static, io::Result<Bytes>> {
    stream::once(async move {
        let mut file = match tokio::fs::File::open(&segment.path).await {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                return stream::empty().boxed();
            }
            Err(error) => return stream::once(async { Err(error) }).boxed(),
        };
        if let Err(error) = file.seek(io::SeekFrom::Start(segment.start)).await {
            return stream::once(async { Err(error) }).boxed();
        }
        ReaderStream::with_capacity(file.take(segment.len), STREAM_CHUNK).boxed()
    })
    .flatten()
    .boxed()
}
