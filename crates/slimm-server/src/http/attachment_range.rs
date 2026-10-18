// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Serving a stored attachment's bytes back with HTTP range support, split out
//! of [`super::attachments`] so that file holds the upload/fetch handlers and
//! this one holds the RFC 9110 `Range` arithmetic and the streamed response it
//! builds. Every response still routes through
//! [`super::attachments::apply_asset_headers`], so a ranged body carries the
//! same security headers a whole one does.

use std::io::SeekFrom;

use axum::body::Body;
use axum::http::{HeaderMap, HeaderValue, StatusCode, header};
use axum::response::{IntoResponse, Response};
use tokio::io::{AsyncReadExt, AsyncSeekExt};
use tokio_util::io::ReaderStream;

use super::attachments::apply_asset_headers;
use super::error::ApiError;

/// Bytes read per chunk of a streamed body; the default 4 KiB costs a blocking-pool hop per read.
const STREAM_CHUNK: usize = 256 * 1024;

/// The byte range a `Range` header resolves to against a known total length.
enum ByteRange {
    /// No usable range: serve the whole body as `200`. Covers an absent header
    /// and, per RFC 9110, a header this server chooses not to honour (a
    /// multi-range request, or a syntactically invalid one), which a client
    /// must accept as a full response.
    Full,
    /// A single satisfiable range, both bounds inclusive: serve `206`.
    Partial { start: u64, end: u64 },
    /// A syntactically valid range that no part of the body can satisfy: serve
    /// `416` so the client learns the length rather than retrying blindly.
    Unsatisfiable,
}

/// Resolves a `Range` request-header value against `total`, following RFC 9110:
/// only `bytes` units, a single range, and anything malformed or multi-range
/// falls back to a full response rather than an error.
fn parse_range(header: Option<&str>, total: u64) -> ByteRange {
    let Some(spec) = header.and_then(|h| h.trim().strip_prefix("bytes=")) else {
        return ByteRange::Full;
    };
    // A comma means multiple ranges; serve the whole body, not a multipart/byteranges response.
    if spec.contains(',') {
        return ByteRange::Full;
    }
    let Some((raw_start, raw_end)) = spec.split_once('-') else {
        return ByteRange::Full;
    };
    let (start, end) = match (raw_start.trim(), raw_end.trim()) {
        ("", "") => return ByteRange::Full,
        // `-N`: the final N bytes. N == 0 requests nothing satisfiable.
        ("", suffix) => {
            let Ok(len) = suffix.parse::<u64>() else {
                return ByteRange::Full;
            };
            if len == 0 || total == 0 {
                return ByteRange::Unsatisfiable;
            }
            (total.saturating_sub(len), total - 1)
        }
        // `start-`: from start to the end of the body.
        (start, "") => {
            let Ok(start) = start.parse::<u64>() else {
                return ByteRange::Full;
            };
            (start, total.saturating_sub(1))
        }
        // `start-end`, end clamped into the body.
        (start, end) => {
            let (Ok(start), Ok(end)) = (start.parse::<u64>(), end.parse::<u64>()) else {
                return ByteRange::Full;
            };
            (start, end.min(total.saturating_sub(1)))
        }
    };
    if total == 0 || start >= total || start > end {
        return ByteRange::Unsatisfiable;
    }
    ByteRange::Partial { start, end }
}

/// Streams an open attachment file as the response, honouring a single
/// `Range`. Always advertises `Accept-Ranges: bytes` and sets an explicit
/// `Content-Length`, neither of which a streamed body carries on its own.
pub(super) async fn serve_ranged(
    mut file: tokio::fs::File,
    total_len: u64,
    range_header: Option<&str>,
    content_type: &str,
    filename: &str,
) -> Result<Response, ApiError> {
    let response = match parse_range(range_header, total_len) {
        ByteRange::Unsatisfiable => {
            let mut response = StatusCode::RANGE_NOT_SATISFIABLE.into_response();
            response.headers_mut().insert(
                header::CONTENT_RANGE,
                HeaderValue::from_str(&format!("bytes */{total_len}"))
                    .unwrap_or_else(|_| HeaderValue::from_static("bytes */0")),
            );
            response
        }
        ByteRange::Full => {
            let body = Body::from_stream(ReaderStream::with_capacity(file, STREAM_CHUNK));
            let mut response = body.into_response();
            set_content_length(response.headers_mut(), total_len);
            response
        }
        ByteRange::Partial { start, end } => {
            file.seek(SeekFrom::Start(start)).await.map_err(|err| {
                tracing::error!(error = %err, "failed to seek within a stored attachment");
                ApiError::Internal
            })?;
            let span = end - start + 1;
            let body =
                Body::from_stream(ReaderStream::with_capacity(file.take(span), STREAM_CHUNK));
            let mut response = body.into_response();
            *response.status_mut() = StatusCode::PARTIAL_CONTENT;
            let headers = response.headers_mut();
            set_content_length(headers, span);
            headers.insert(
                header::CONTENT_RANGE,
                HeaderValue::from_str(&format!("bytes {start}-{end}/{total_len}"))
                    .unwrap_or_else(|_| HeaderValue::from_static("bytes */0")),
            );
            response
        }
    };
    let mut response = response;
    let headers = response.headers_mut();
    headers.insert(header::ACCEPT_RANGES, HeaderValue::from_static("bytes"));
    apply_asset_headers(headers, content_type, filename);
    Ok(response)
}

fn set_content_length(headers: &mut HeaderMap, len: u64) {
    if let Ok(value) = HeaderValue::from_str(&len.to_string()) {
        headers.insert(header::CONTENT_LENGTH, value);
    }
}

#[cfg(test)]
mod tests {
    use futures_util::StreamExt;

    use super::*;

    #[tokio::test]
    async fn a_large_body_streams_in_few_chunks() {
        let path = std::env::temp_dir().join(format!("slimm-range-{}", uuid::Uuid::now_v7()));
        tokio::fs::write(&path, vec![7u8; 2 * 1024 * 1024])
            .await
            .unwrap();
        let file = tokio::fs::File::open(&path).await.unwrap();

        let Ok(response) = serve_ranged(file, 2 * 1024 * 1024, None, "image/png", "a.png").await
        else {
            panic!("a whole file is servable");
        };
        let chunks = response.into_body().into_data_stream().count().await;

        tokio::fs::remove_file(&path).await.unwrap();
        assert!(chunks <= 16, "{chunks} chunks for 2 MiB");
    }
}
