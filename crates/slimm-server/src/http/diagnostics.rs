// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The connection test: a latency ping, and capped download and upload transfers.
//!
//! The transfers measure the path between a client and this server, so they move
//! throwaway bytes only: the download is generated, the upload is counted and
//! discarded, and neither touches disk or the database.

use std::time::Instant;

use axum::Router;
use axum::body::{Body, Bytes};
use axum::http::{HeaderMap, HeaderValue, StatusCode, header};
use axum::response::Response;
use axum::routing::{get, post};
use futures_util::StreamExt;
use serde::{Deserialize, Serialize};

use super::AppState;
use super::error::ApiError;
use super::extract::{AuthedLimited, DIAGNOSTIC_PING, DIAGNOSTIC_TRANSFER, Json, Query};
use crate::store::now_ms;

/// The most one transfer may move, in bytes; a bigger ask is refused, never trimmed.
pub const MAX_TRANSFER_BYTES: u64 = 64 * 1024 * 1024;

const DEFAULT_DOWNLOAD_BYTES: u64 = 1024 * 1024;
const CHUNK_BYTES: usize = 64 * 1024;

/// The latency ping, mounted by [`super::router`].
pub fn ping_routes() -> Router<AppState> {
    Router::new().route("/diagnostics/ping", get(ping))
}

/// The transfers, kept out of the router's total-time timeout: a slow link legitimately
/// takes longer than it to move 64 MiB.
pub fn transfer_routes() -> Router<AppState> {
    Router::new()
        .route("/diagnostics/download", get(download))
        .route("/diagnostics/upload", post(upload))
}

#[derive(Serialize)]
struct PingDto {
    server_time_ms: i64,
}

async fn ping(AuthedLimited(_ctx): AuthedLimited<DIAGNOSTIC_PING>) -> Json<PingDto> {
    Json(PingDto {
        server_time_ms: now_ms(),
    })
}

#[derive(Deserialize)]
struct DownloadParams {
    bytes: Option<u64>,
}

/// Incompressible filler, so a proxy that compresses cannot flatter the speed.
fn filler() -> Bytes {
    let mut state: u64 = 0x9E37_79B9_7F4A_7C15;
    let mut chunk = Vec::with_capacity(CHUNK_BYTES);
    while chunk.len() < CHUNK_BYTES {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        chunk.extend_from_slice(&state.to_le_bytes());
    }
    Bytes::from(chunk)
}

async fn download(
    AuthedLimited(_ctx): AuthedLimited<DIAGNOSTIC_TRANSFER>,
    Query(params): Query<DownloadParams>,
) -> Result<Response, ApiError> {
    let total = params.bytes.unwrap_or(DEFAULT_DOWNLOAD_BYTES);
    if total == 0 || total > MAX_TRANSFER_BYTES {
        return Err(ApiError::BadRequest("bytes is out of range"));
    }
    let filler = filler();
    let body = Body::from_stream(futures_util::stream::unfold(total, move |left| {
        let chunk = filler.clone();
        async move {
            if left == 0 {
                return None;
            }
            let take = left.min(chunk.len() as u64) as usize;
            Some((
                Ok::<_, std::convert::Infallible>(chunk.slice(..take)),
                left - take as u64,
            ))
        }
    }));
    let mut response = Response::new(body);
    let headers = response.headers_mut();
    headers.insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("application/octet-stream"),
    );
    headers.insert(header::CONTENT_LENGTH, HeaderValue::from(total));
    headers.insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    Ok(response)
}

#[derive(Serialize)]
struct UploadResultDto {
    bytes: u64,
    duration_ms: u64,
    timed_bytes: u64,
    duration_us: u64,
}

fn declared_length(headers: &HeaderMap) -> Option<u64> {
    headers
        .get(header::CONTENT_LENGTH)?
        .to_str()
        .ok()?
        .parse()
        .ok()
}

async fn upload(
    AuthedLimited(_ctx): AuthedLimited<DIAGNOSTIC_TRANSFER>,
    headers: HeaderMap,
    body: Body,
) -> Result<(StatusCode, Json<UploadResultDto>), ApiError> {
    if declared_length(&headers).is_some_and(|length| length > MAX_TRANSFER_BYTES) {
        return Err(ApiError::PayloadTooLarge);
    }
    let started = Instant::now();
    let mut seen: u64 = 0;
    let mut timing = ReceiptTiming::default();
    let mut stream = body.into_data_stream();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|_| ApiError::BadRequest("upload stream ended early"))?;
        seen += chunk.len() as u64;
        if seen > MAX_TRANSFER_BYTES {
            return Err(ApiError::PayloadTooLarge);
        }
        timing.record(chunk.len() as u64);
    }
    Ok((
        StatusCode::OK,
        Json(UploadResultDto {
            bytes: seen,
            duration_ms: u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX),
            timed_bytes: timing.timed_bytes,
            duration_us: timing.elapsed_us(),
        }),
    ))
}

/// Times a body from its first chunk to its last, leaving the first chunk's bytes out, so
/// whatever the socket had buffered before the handler ran does not flatter the speed.
#[derive(Default)]
struct ReceiptTiming {
    first_chunk_at: Option<Instant>,
    last_chunk_at: Option<Instant>,
    timed_bytes: u64,
}

impl ReceiptTiming {
    fn record(&mut self, len: u64) {
        let now = Instant::now();
        if self.first_chunk_at.is_none() {
            self.first_chunk_at = Some(now);
        } else {
            self.timed_bytes += len;
        }
        self.last_chunk_at = Some(now);
    }

    fn elapsed_us(&self) -> u64 {
        match (self.first_chunk_at, self.last_chunk_at) {
            (Some(first), Some(last)) => {
                u64::try_from(last.duration_since(first).as_micros()).unwrap_or(u64::MAX)
            }
            _ => 0,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn timing_leaves_the_first_chunk_out() {
        let mut timing = ReceiptTiming::default();
        timing.record(100);
        assert_eq!(timing.timed_bytes, 0);
        std::thread::sleep(std::time::Duration::from_millis(5));
        timing.record(50);
        timing.record(25);
        assert_eq!(timing.timed_bytes, 75);
        assert!(timing.elapsed_us() >= 5_000);
    }

    #[test]
    fn an_empty_body_has_no_timing() {
        let timing = ReceiptTiming::default();
        assert_eq!((timing.timed_bytes, timing.elapsed_us()), (0, 0));
    }
}
