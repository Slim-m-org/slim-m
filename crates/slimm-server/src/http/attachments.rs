// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Attachment routes: upload bytes once, reference them by content hash when
//! sending a message ([`super::messages`]), fetch them back here.
//!
//! Upload accepts only a fixed content-type allowlist ([`media`]), decided by
//! sniffing the bytes themselves - never a client-declared Content-Type
//! header and never a filename extension, both of which a client fully
//! controls. That is the actual security boundary: this deployment has no
//! content or media scanning by owner decision, so what gets accepted and how
//! it is served back is the whole defense against a stored-XSS upload.
//!
//! Fetch is the other half of that boundary. It is gated on the same
//! VIEW_CHANNEL permission a caller needs to read the message an attachment
//! belongs to - an unguessable hex id is not access control on its own, and
//! this never treats it as such.

use axum::Router;
use axum::body::Body;
use axum::extract::{Path, State};
use axum::http::{HeaderMap, HeaderName, HeaderValue, StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use serde::Deserialize;

use super::AppState;
use super::error::ApiError;
use super::extract::{ASSET, AuthedLimited, Json, Query, UPLOAD};
use super::message_dto::AttachmentDto;
use crate::media::{self, StreamError};
use crate::permissions::Permissions;
use crate::store::AttachmentSummary;

/// A fetched attachment's bytes never change (they are keyed by their own
/// content hash), so a client may cache one forever.
const IMMUTABLE_CACHE: &str = "private, max-age=31536000, immutable";

/// The attachment routes, mounted by [`super::router`] right after
/// `users::routes()`.
///
/// No `DefaultBodyLimit` layer: [`upload`] takes the raw request body and
/// streams it, which bypasses that layer (it only bounds the buffering
/// extractors), so the per-upload ceiling is enforced inside the handler as it
/// reads, against `state.media.max_attachment_bytes()`. That is stricter than a
/// layer would be - the body is never buffered whole to measure it - and reads
/// the same operator-configured ceiling.
pub fn routes() -> Router<AppState> {
    Router::new().route("/attachments/{attachment_id}", get(fetch))
}

/// The upload route on its own so the router can keep it out of the total-time
/// request timeout; see `http::router`.
pub fn upload_routes() -> Router<AppState> {
    Router::new().route("/attachments", post(upload))
}

// --- Wire types ---

#[derive(Deserialize)]
struct UploadParams {
    filename: Option<String>,
}

// --- Handlers ---

/// Stores uploaded bytes under their own sha256 and returns the hex id a
/// message can then reference.
///
/// The body is streamed to disk while being hashed rather than buffered into a
/// `Vec` first, so a 1 GiB upload costs a bounded amount of memory instead of
/// holding the whole file (and a copy of it) in RAM. That is why this takes the
/// raw [`Body`] rather than the `Bytes` extractor: `Bytes` would buffer the
/// whole request before the handler ran.
///
/// The order the checks run in is the point. `AuthedLimited` authenticates and
/// charges the rate limit before the body is touched at all; then the
/// ATTACH_FILES check and the declared-length check run before a single byte is
/// streamed, so a caller with no permission, or one announcing an oversized
/// upload, never costs the process the disk write. Only then is the body
/// consumed. A lying or chunked client that under-declares its length is still
/// caught, by the running byte count inside [`media::Media::stream_attachment`].
///
/// The file is placed before the metadata row on purpose: a crash between the
/// two leaves an orphaned file (harmless, eventually swept) rather than a row
/// that promises bytes which were never written.
///
/// Requires ATTACH_FILES deployment-wide. An upload names no channel, so the
/// per-channel check still happens when the resulting id is attached to a
/// message; until this bit was checked at all a member denied attachments
/// everywhere - or one currently timed out - could still write bytes into
/// media storage.
async fn upload(
    AuthedLimited(ctx): AuthedLimited<UPLOAD>,
    Query(params): Query<UploadParams>,
    headers: HeaderMap,
    State(state): State<AppState>,
    body: Body,
) -> Result<(StatusCode, Json<AttachmentDto>), ApiError> {
    // Before the body streams, so no permission means no disk write.
    if !state
        .store
        .base_permissions(ctx.user_id)
        .await?
        .contains(Permissions::ATTACH_FILES)
    {
        return Err(ApiError::Forbidden);
    }

    let max_bytes = state.media.max_attachment_bytes();
    // A fast-fail on a declared oversize; the true size is re-checked below.
    if let Some(declared) = content_length(&headers) {
        if declared > max_bytes {
            return Err(ApiError::PayloadTooLarge);
        }
        room_for(&state, declared as i64).await?;
    }

    let pending = state
        .media
        .stream_attachment(body.into_data_stream(), max_bytes)
        .await
        .map_err(upload_stream_error)?;

    if pending.size() == 0 {
        pending.abandon().await.ok();
        return Err(ApiError::BadRequest("attachment is empty"));
    }
    // Decided from the bytes only; `sniffable` guards the streamed-prefix seam.
    let Some(content_type) = media::sniff_content_type(sniffable(pending.sniff_prefix())) else {
        pending.abandon().await.ok();
        return Err(ApiError::BadRequest("unsupported attachment type"));
    };
    // The true streamed size no Content-Length can hide; a refusal drops the temp.
    if let Err(err) = room_for(&state, pending.size() as i64).await {
        pending.abandon().await.ok();
        return Err(err);
    }

    let filename = media::sanitize_filename(params.filename.as_deref().unwrap_or("file"));
    let hex_id = pending.hex_id().to_owned();
    let size = pending.size() as i64;
    let sha256 = media::from_hex(&hex_id).expect("a hex id from sha256 is well-formed hex");

    // Bytes before the metadata row; see the ordering note on this function.
    pending.commit().await.map_err(|err| {
        tracing::error!(error = %err, "failed to store a streamed attachment");
        ApiError::Internal
    })?;
    state
        .store
        .store_attachment(&sha256, size, content_type, &filename, Some(ctx.user_id))
        .await?;

    Ok((
        StatusCode::CREATED,
        Json(AttachmentDto::from(AttachmentSummary {
            id: hex_id,
            filename,
            content_type: content_type.to_owned(),
            size,
        })),
    ))
}

/// The `Content-Length` a client declared, when it sent a well-formed one. A
/// fast-fail hint only: the running byte count during the stream is what
/// actually bounds an upload, since this header is absent on a chunked body and
/// a client controls it regardless.
fn content_length(headers: &HeaderMap) -> Option<u64> {
    headers
        .get(header::CONTENT_LENGTH)?
        .to_str()
        .ok()?
        .parse()
        .ok()
}

/// The prefix bytes to sniff, given the type is decided from a captured prefix
/// rather than the whole file (see [`media::Media::stream_attachment`]). Every
/// magic-number type decides on bytes at the very start, so trimming the end
/// changes none of them; the `text/plain` fallback runs `str::from_utf8` over
/// the whole slice, which a prefix cut mid multi-byte character would fail
/// spuriously. Only a trailing incomplete sequence is trimmed - a genuinely
/// invalid byte earlier leaves the slice intact so the text check still
/// (correctly) refuses it.
fn sniffable(prefix: &[u8]) -> &[u8] {
    match std::str::from_utf8(prefix) {
        Ok(_) => prefix,
        Err(err) if err.error_len().is_none() => &prefix[..err.valid_up_to()],
        Err(_) => prefix,
    }
}

/// Maps a stream failure to the status a caller sees: too big is a 413, a
/// severed or malformed client stream is a 400, and a disk fault is a 500 that
/// says nothing about why.
fn upload_stream_error(err: StreamError) -> ApiError {
    match err {
        StreamError::TooLarge => ApiError::PayloadTooLarge,
        StreamError::Body => ApiError::BadRequest("upload stream ended early"),
        StreamError::Io(err) => {
            tracing::error!(error = %err, "failed to stream an uploaded attachment");
            ApiError::Internal
        }
    }
}

/// Serves stored bytes back, gated on the same VIEW_CHANNEL a caller needs to
/// read the message the attachment belongs to.
///
/// The check runs across every channel that has attached these bytes, because
/// content addressing means more than one message, in more than one channel,
/// can share them. An id nothing has attached - still mid-compose, or already
/// swept as an orphan - reports the same 404 as one that never existed, except
/// to whoever uploaded it, who may always fetch their own upload: existence
/// follows permission here exactly as it does for a channel or a message
/// elsewhere in this API.
async fn fetch(
    AuthedLimited(ctx): AuthedLimited<ASSET>,
    Path(attachment_id): Path<String>,
    headers: HeaderMap,
    State(state): State<AppState>,
) -> Result<Response, ApiError> {
    let sha256 = media::from_hex(&attachment_id)
        .filter(|bytes| bytes.len() == 32)
        .ok_or(ApiError::BadRequest("invalid attachment id"))?;

    // The uploader may always fetch what they uploaded, even before it is on any message
    // (previewing a just-picked GIF needs it); everyone else needs VIEW_CHANNEL on a
    // referencing channel. `may_link` shares this rule.
    let allowed = state
        .store
        .can_fetch_attachment(ctx.user_id, &sha256)
        .await?;
    if !allowed {
        // 404, not 403, and the difference is the whole point. An attachment id
        // is the content's sha256, so anyone holding a candidate file can
        // compute it; a 403-versus-404 split would tell them whether those
        // exact bytes were shared in a DM or a private channel they cannot see.
        // Existence follows permission here, the same collapse search and the
        // channel API already make.
        return Err(ApiError::NotFound("attachment not found"));
    }

    let meta = state
        .store
        .attachment_summary(&sha256)
        .await?
        .ok_or(ApiError::NotFound("attachment not found"))?;
    let (file, total_len) = state
        .media
        .open_attachment(&attachment_id)
        .await
        .map_err(|err| {
            tracing::error!(error = %err, "failed to open a stored attachment");
            ApiError::Internal
        })?;

    let range_header = headers.get(header::RANGE).and_then(|v| v.to_str().ok());
    super::attachment_range::serve_ranged(
        file,
        total_len,
        range_header,
        &meta.content_type,
        &meta.filename,
    )
    .await
}

/// Serves already-buffered bytes, for the small assets that are read whole
/// anyway: avatars (`super::users`) and custom emoji (`super::emoji`). Large
/// attachments stream instead, through [`super::attachment_range::serve_ranged`];
/// both share [`apply_asset_headers`], so every asset response carries
/// identical security headers.
pub(crate) fn serve(bytes: Vec<u8>, content_type: &str, filename: &str) -> Response {
    let mut response = Body::from(bytes).into_response();
    apply_asset_headers(response.headers_mut(), content_type, filename);
    response
}

/// Sets the security and caching headers every asset response carries,
/// buffered ([`serve`]) or streamed ([`serve_ranged`]), so both are governed
/// by one definition rather than two that can drift.
///
/// `content_type` is never trusted from the caller; every call site passes a
/// value this module already sniffed from the stored bytes, so this only ever
/// serves an allowlisted type. The filename is re-sanitized here even though
/// the stored value already was: it is cheap and idempotent, and it means the
/// response never depends on every future write path having remembered to.
pub(super) fn apply_asset_headers(headers: &mut HeaderMap, content_type: &str, filename: &str) {
    let disposition_kind = if media::is_inline(content_type) {
        "inline"
    } else {
        "attachment"
    };
    let safe_name = media::sanitize_filename(filename);
    let disposition = format!("{disposition_kind}; filename=\"{safe_name}\"");

    headers.insert(
        header::CONTENT_TYPE,
        HeaderValue::from_str(content_type)
            .unwrap_or_else(|_| HeaderValue::from_static("application/octet-stream")),
    );
    // `sanitize_filename` guarantees printable ASCII so this cannot fail; the
    // fallback keeps a future change to that guarantee a response, not a panic.
    let disposition_value = HeaderValue::from_str(&disposition)
        .unwrap_or_else(|_| HeaderValue::from_static("attachment"));
    headers.insert(header::CONTENT_DISPOSITION, disposition_value);
    // Not a named constant in the `http` crate (it is a non-standard header),
    // unlike Content-Type and Content-Disposition above.
    headers.insert(
        HeaderName::from_static("x-content-type-options"),
        HeaderValue::from_static("nosniff"),
    );
    headers.insert(
        header::CACHE_CONTROL,
        HeaderValue::from_static(IMMUTABLE_CACHE),
    );
}

/// Refuses the upload if storing `incoming` bytes would put the deployment over
/// `SLIMM_MAX_TOTAL_ATTACHMENT_BYTES`.
///
/// Checked before the bytes are written, never after, so a refusal leaves
/// nothing on disk to reclaim - the same ordering the per-upload size limit
/// above it uses.
///
/// Two things it deliberately is not. It is not a reservation: two uploads
/// racing the last few bytes can both pass and land slightly over, which costs
/// at most one attachment's worth and is the right trade against serialising
/// every upload behind a write lock. And it is not a quota per account, which
/// would need a policy answer about who gets how much that nobody has asked
/// for; this is the disk, and the disk is shared.
pub(super) async fn room_for(state: &AppState, incoming: i64) -> Result<(), ApiError> {
    let Some(ceiling) = state.media.max_total_attachment_bytes() else {
        return Ok(());
    };
    let held = state.store.total_attachment_bytes().await?;
    if held.saturating_add(incoming) as u64 > ceiling {
        return Err(ApiError::InsufficientStorage);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// HTML and SVG sniff to the `text/plain` fallback (see
    /// `media::content_type`'s module doc), so this drives the real `serve`
    /// handler with each and asserts the response a browser actually gets:
    /// a forced download, never an inline render, with `nosniff` set too.
    #[test]
    fn html_and_svg_sniffed_as_text_are_served_as_a_forced_download() {
        for bytes in [
            b"<html><body><script>alert(1)</script></body></html>".to_vec(),
            b"<svg xmlns=\"http://www.w3.org/2000/svg\" onload=\"alert(1)\"></svg>".to_vec(),
        ] {
            let content_type = media::sniff_content_type(&bytes);
            assert_eq!(content_type, Some("text/plain"));
            let response = serve(bytes, content_type.unwrap(), "evil.html");

            let disposition = response
                .headers()
                .get(header::CONTENT_DISPOSITION)
                .unwrap()
                .to_str()
                .unwrap();
            assert!(
                disposition.starts_with("attachment"),
                "must never be inline: {disposition}"
            );

            let nosniff = response
                .headers()
                .get(HeaderName::from_static("x-content-type-options"))
                .unwrap();
            assert_eq!(nosniff, "nosniff");
        }
    }
}
