// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `GET /space/server-logs`: the newest server log lines as plain text, for an
//! admin to download (decision 0129).
//!
//! Streamed file by file from a plan made up front, so a download holds one
//! read buffer rather than the whole text, and one download runs at a time.

use std::io;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

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
use tokio::sync::{SemaphorePermit, oneshot};
use tokio::time::Instant;
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
/// Stands in for a planned file deleted before the download could open it.
pub const MISSING_LINES_NOTE: &str =
    "[lines missing: a log file was deleted during the download]\n";
/// How long a reader may take nothing before the next download may start.
const IDLE_LIMIT: Duration = Duration::from_secs(30);
/// The longest one download holds its turn, the client's own transfer deadline.
const TIME_LIMIT: Duration = Duration::from_secs(180);

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
    let (truncated, opened) = tokio::task::spawn_blocking(move || {
        if let Some(logging) = crate::logging::installed() {
            logging.flush();
        }
        let plan = plan_recent(&dir, MAX_DOWNLOAD_BYTES, crate::logging::today())?;
        let opened: Vec<_> = plan.segments.into_iter().map(open_segment).collect();
        io::Result::Ok((plan.truncated, opened))
    })
    .await
    .map_err(anyhow::Error::from)?
    .map_err(anyhow::Error::from)?;
    let note = truncated.then(|| Ok(Bytes::from_static(OLDER_LINES_NOTE.as_bytes())));
    let turn = Turn::take(permit, IDLE_LIMIT, TIME_LIMIT);
    let body = stream::iter(note)
        .chain(stream::iter(opened).flat_map(segment_stream))
        .map(move |chunk| turn.read(chunk));
    let mut response = Body::from_stream(body).into_response();
    response.headers_mut().insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("text/plain; charset=utf-8"),
    );
    Ok(response)
}

/// A planned stretch with its file already open, so a file pruned mid-download still reads.
struct OpenSegment {
    file: Option<std::fs::File>,
    start: u64,
    len: u64,
}

fn open_segment(segment: Segment) -> OpenSegment {
    OpenSegment {
        file: std::fs::File::open(&segment.path).ok(),
        start: segment.start,
        len: segment.len,
    }
}

/// One planned stretch, never past its planned length; a file gone before it was opened says so.
fn segment_stream(segment: OpenSegment) -> stream::BoxStream<'static, io::Result<Bytes>> {
    let Some(file) = segment.file else {
        return stream::once(async { Ok(Bytes::from_static(MISSING_LINES_NOTE.as_bytes())) })
            .boxed();
    };
    stream::once(async move {
        let mut file = tokio::fs::File::from_std(file);
        if let Err(error) = file.seek(io::SeekFrom::Start(segment.start)).await {
            return stream::once(async { Err(error) }).boxed();
        }
        ReaderStream::with_capacity(file.take(segment.len), STREAM_CHUNK).boxed()
    })
    .flatten()
    .boxed()
}

/// One download's hold on [`DOWNLOADS`]: given back when its body is dropped, when the
/// reader takes nothing for [`IDLE_LIMIT`], or after [`TIME_LIMIT`], so a stalled or
/// vanished reader cannot keep every later download at 429.
struct Turn {
    started: Instant,
    last_read_ms: Arc<AtomicU64>,
    longest: Duration,
    _done: oneshot::Sender<()>,
}

impl Turn {
    fn take(permit: SemaphorePermit<'static>, idle: Duration, longest: Duration) -> Self {
        let started = Instant::now();
        let last_read_ms = Arc::new(AtomicU64::new(0));
        let (done, mut finished) = oneshot::channel::<()>();
        let watched = last_read_ms.clone();
        tokio::spawn(async move {
            let _permit = permit;
            loop {
                let read_at = started + Duration::from_millis(watched.load(Ordering::Relaxed));
                let wake = (read_at + idle).min(started + longest);
                if Instant::now() >= wake {
                    return;
                }
                tokio::select! {
                    _ = &mut finished => return,
                    () = tokio::time::sleep_until(wake) => {}
                }
            }
        });
        Self {
            started,
            last_read_ms,
            longest,
            _done: done,
        }
    }

    /// Passes a chunk on and notes the read; past [`TIME_LIMIT`] it ends the body instead.
    fn read(&self, chunk: io::Result<Bytes>) -> io::Result<Bytes> {
        let elapsed = self.started.elapsed();
        if elapsed >= self.longest {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "the log download ran past its time limit",
            ));
        }
        let millis = u64::try_from(elapsed.as_millis()).unwrap_or(u64::MAX);
        self.last_read_ms.store(millis, Ordering::Relaxed);
        chunk
    }
}

#[cfg(test)]
mod tests;
