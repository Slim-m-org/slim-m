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
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::Response;
use axum::routing::{get, post};
use serde::Deserialize;

use super::AppState;
use super::error::ApiError;
use super::extract::{ASSET, AuthedLimited, Json, Query, UPLOAD, user_limit_key};
use super::message_dto::AttachmentDto;
use super::storage_room::{reserve_room, room_for};
use crate::media::{self, StreamError};
use crate::store::AttachmentSummary;

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
    Router::new()
        .route("/attachments", post(upload))
        .merge(super::attachment_uploads::routes())
}

// --- Wire types ---

#[derive(Deserialize)]
struct UploadParams {
    filename: Option<String>,
    /// Where the file is headed; see `attachment_uploads::may_attach`.
    channel_id: Option<String>,
    #[serde(flatten)]
    voice: super::attachment_voice::VoiceParams,
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
/// Requires ATTACH_FILES in the channel the upload names, or deployment-wide
/// when it names none; the per-channel check still happens when the resulting
/// id is attached to a message. Until this bit was checked at all a member
/// denied attachments everywhere - or one currently timed out - could still
/// write bytes into media storage.
async fn upload(
    AuthedLimited(ctx): AuthedLimited<UPLOAD>,
    Query(params): Query<UploadParams>,
    headers: HeaderMap,
    State(state): State<AppState>,
    body: Body,
) -> Result<(StatusCode, Json<AttachmentDto>), ApiError> {
    // Before the body streams, so no permission means no disk write.
    super::attachment_uploads::may_attach(&state, ctx.user_id, params.channel_id.as_deref())
        .await?;

    let voice = params.voice.parse()?;
    let max_bytes = effective_attachment_max(&state).await?;
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
    let content_type = media::attachment_content_type(sniffable(pending.sniff_prefix()));
    if let Err(err) = super::attachment_voice::must_be_audio(voice.as_ref(), content_type) {
        pending.abandon().await.ok();
        return Err(err);
    }
    // The true streamed size no Content-Length can hide; a refusal drops the temp.
    let mut reservation = match reserve_room(&state, pending.size() as i64, None).await {
        Ok(reservation) => reservation,
        Err(err) => {
            pending.abandon().await.ok();
            return Err(err);
        }
    };

    let filename = media::sanitize_display_filename(params.filename.as_deref().unwrap_or("file"));
    if let Some(replacement) = super::attachment_compress::prepare(
        &state,
        pending.path(),
        pending.size(),
        pending.sniff_prefix(),
        &filename,
    )
    .await?
    {
        let received = super::attachment_compress::Received::Pending(pending);
        drop(std::mem::replace(
            &mut reservation,
            media::Reservation::none(),
        ));
        let summary = replacement.store(&state, ctx.user_id, received).await?;
        return Ok((StatusCode::CREATED, Json(AttachmentDto::from(summary))));
    }
    let hex_id = pending.hex_id().to_owned();
    let size = pending.size() as i64;
    let sha256 = media::from_hex(&hex_id).expect("a hex id from sha256 is well-formed hex");

    // Bytes before the metadata row; see the ordering note on this function.
    let placing = state.media.blob_guard().await;
    pending.commit().await.map_err(|err| {
        tracing::error!(error = %err, "failed to store a streamed attachment");
        ApiError::Internal
    })?;
    match &voice {
        Some(voice) => {
            state
                .store
                .store_voice_attachment(&sha256, size, content_type, &filename, ctx.user_id, voice)
                .await?
        }
        None => {
            state
                .store
                .store_attachment(&sha256, size, content_type, &filename, Some(ctx.user_id))
                .await?
        }
    }
    drop(placing);
    drop(reservation);
    state.media.prewarm_preview(&hex_id, content_type);

    Ok((
        StatusCode::CREATED,
        Json(AttachmentDto::from(AttachmentSummary {
            id: hex_id,
            filename,
            content_type: content_type.to_owned(),
            size,
            spoiler: false,
            original: None,
            voice,
            transcript: None,
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
pub(super) fn sniffable(prefix: &[u8]) -> &[u8] {
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

/// Served when the caller has no name of their own for the bytes.
const NEUTRAL_FILENAME: &str = "attachment";

/// Query for [`fetch`].
#[derive(Deserialize, Default)]
pub(super) struct FetchParams {
    /// Asks for a bounded-size preview of a still image; see [`super::attachment_preview`].
    w: Option<u32>,
    /// With `w`, also answers an animated WebP or PNG with its first frame.
    still: Option<bool>,
    /// Asks for the uploaded original kept beside a compressed copy.
    original: Option<bool>,
}

impl FetchParams {
    /// The whole file, as stored or as uploaded, with no preview.
    pub(super) fn whole(original: bool) -> Self {
        Self {
            original: original.then_some(true),
            ..Self::default()
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
    Query(params): Query<FetchParams>,
    headers: HeaderMap,
    State(state): State<AppState>,
) -> Result<Response, ApiError> {
    let slot = super::download_slots::take(&state.limiter, &user_limit_key(ctx.user_id))?;
    let response = serve_for(&state, ctx.user_id, &attachment_id, params, &headers).await?;
    Ok(super::download_slots::hold_until_sent(slot, response))
}

/// The sha256 an attachment id spells, when the id is well formed.
pub(super) fn parse_attachment_id(attachment_id: &str) -> Result<Vec<u8>, ApiError> {
    media::from_hex(attachment_id)
        .filter(|bytes| bytes.len() == 32)
        .ok_or(ApiError::BadRequest("invalid attachment id"))
}

/// Whether [user_id] may read these bytes, by the rule [`fetch`] and a download link share.
pub(super) async fn may_fetch(
    state: &AppState,
    user_id: crate::ids::UserId,
    sha256: &[u8],
) -> Result<bool, ApiError> {
    // The uploader may always fetch what they uploaded, even before it is on any message
    // (previewing a just-picked GIF needs it); everyone else needs VIEW_CHANNEL on a
    // referencing channel, a rule `may_link` shares; a screen stamp adds a fetch-only grant.
    Ok(state.store.can_fetch_attachment(user_id, sha256).await?
        || super::screen_stamps::stamp_access::may_fetch_stamp_picture(state, user_id, sha256)
            .await)
}

/// Serves an attachment to [user_id], who has already been authenticated by whatever route got here.
pub(super) async fn serve_for(
    state: &AppState,
    user_id: crate::ids::UserId,
    attachment_id: &str,
    params: FetchParams,
    headers: &HeaderMap,
) -> Result<Response, ApiError> {
    let sha256 = parse_attachment_id(attachment_id)?;
    let attachment_id = media::to_hex(&sha256);
    if !may_fetch(state, user_id, &sha256).await? {
        // 404, not 403, and the difference is the whole point. An attachment id
        // is the content's sha256, so anyone holding a candidate file can
        // compute it; a 403-versus-404 split would tell them whether those
        // exact bytes were shared in a DM or a private channel they cannot see.
        // Existence follows permission here, the same collapse search and the
        // channel API already make.
        return Err(ApiError::NotFound("attachment not found"));
    }

    let mut meta = state
        .store
        .attachment_summary(&sha256)
        .await?
        .ok_or(ApiError::NotFound("attachment not found"))?;
    meta.filename = state
        .store
        .attachment_display_filename(user_id, &sha256)
        .await?
        .unwrap_or_else(|| NEUTRAL_FILENAME.to_owned());
    if params.original == Some(true) {
        return super::attachment_original::serve(
            state,
            &attachment_id,
            &sha256,
            &meta.filename,
            headers,
        )
        .await;
    }
    if let Some(width) = params.w
        && let Some(response) = super::attachment_preview::serve(
            &state.media,
            &attachment_id,
            &meta,
            super::attachment_preview::Request {
                width,
                still: params.still == Some(true),
            },
            headers,
        )
        .await
    {
        return Ok(response);
    }
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

/// The operator's ceiling, lowered by the admin's Space setting when one is set.
pub(super) async fn effective_attachment_max(state: &AppState) -> Result<u64, ApiError> {
    let ceiling = state.media.max_attachment_bytes();
    Ok(match state.store.attachment_max_bytes().await? {
        0 => ceiling,
        admin => admin.min(ceiling),
    })
}
