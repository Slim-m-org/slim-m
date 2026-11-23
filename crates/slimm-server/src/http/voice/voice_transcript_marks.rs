// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Marks and notes on a call transcript (decision 0113, amended 2026-11-22). Reading
//! needs what reading the transcript needs; adding needs being in the call while it
//! is transcribed; removing is for the author or a channel's message moderator.

use axum::Router;
use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::http::request::Parts;
use axum::routing::{get, put};
use serde::{Deserialize, Serialize};

use super::super::AppState;
use super::super::error::ApiError;
use super::super::extract::{AUTHED_READ, Authed, AuthedLimited, Json, enforce};
use super::super::messages::parse_uuid;
use super::voice_transcripts::readable;
use crate::call_audio::marks;
use crate::hidden_chars::is_hidden_char;
use crate::ids::{CallTranscriptMarkId, UserId};
use crate::permissions::Permissions;
use crate::ratelimit::Class;
use crate::store::{
    CallTranscript, MarkKind, MarkSource, NewMark, PutMark, TranscriptMark, now_ms,
};
use crate::voice::Listing;

/// The longest note, in characters.
pub const MAX_NOTE_CHARS: usize = 500;
/// How soon one person may mark the same call again.
const MANUAL_GAP_MS: i64 = 2_000;

pub(super) fn routes() -> Router<AppState> {
    Router::new()
        .route("/voice/transcripts/{transcript_id}/marks", get(list))
        .route(
            "/voice/transcripts/{transcript_id}/marks/{mark_id}",
            put(add).delete(remove),
        )
}

/// One mark as a reader sees it, read back or sent live.
#[derive(Serialize)]
pub(in crate::http) struct MarkDto {
    id: String,
    transcript_id: String,
    author_id: String,
    at: i64,
    /// The line the mark points at: the newest one kept when it was made.
    line_seq: Option<i64>,
    kind: &'static str,
    /// The note; null on a plain mark.
    text: Option<String>,
    /// `manual` for the button or a hotkey, `voice` for the spoken command.
    source: &'static str,
}

impl From<&TranscriptMark> for MarkDto {
    fn from(mark: &TranscriptMark) -> Self {
        Self {
            id: mark.id.to_string(),
            transcript_id: mark.transcript_id.to_string(),
            author_id: mark.author_id.to_string(),
            at: mark.at,
            line_seq: mark.line_seq,
            kind: mark.kind.as_str(),
            text: mark.text.clone(),
            source: mark.source.as_str(),
        }
    }
}

#[derive(Serialize)]
struct MarksDto {
    marks: Vec<MarkDto>,
}

#[derive(Deserialize)]
struct PutMarkDto {
    kind: String,
    #[serde(default)]
    text: Option<String>,
}

fn reading() -> Permissions {
    Permissions::VIEW_CHANNEL.union(Permissions::VIEW_TRANSCRIPTS)
}

async fn list(
    AuthedLimited(ctx): AuthedLimited<AUTHED_READ>,
    Path(id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<MarksDto>, ApiError> {
    let transcript = readable(&state, ctx.user_id, &id, reading()).await?;
    let marks = state.store.call_transcript_marks(transcript.id).await?;
    Ok(Json(MarksDto {
        marks: marks.iter().map(MarkDto::from).collect(),
    }))
}

/// The kind and note a body asks for, refused before anything is read.
fn parse_body(body: &PutMarkDto) -> Result<(MarkKind, Option<&str>), ApiError> {
    match (body.kind.as_str(), body.text.as_deref().map(str::trim)) {
        ("mark", None) => Ok((MarkKind::Mark, None)),
        ("mark", Some(_)) => Err(ApiError::BadRequest("a mark has no text; send kind note")),
        ("note", Some(text)) if !text.is_empty() => {
            if text.chars().count() > MAX_NOTE_CHARS {
                return Err(ApiError::BadRequest(
                    "a note must be 500 characters or fewer",
                ));
            }
            if text.chars().any(is_hidden_char) {
                return Err(ApiError::BadRequest(
                    "a note must not contain control or invisible characters",
                ));
            }
            Ok((MarkKind::Note, Some(text)))
        }
        ("note", _) => Err(ApiError::BadRequest("a note needs text")),
        _ => Err(ApiError::BadRequest("kind must be mark or note")),
    }
}

fn mark_id(raw: &str) -> Result<CallTranscriptMarkId, ApiError> {
    Ok(CallTranscriptMarkId(parse_uuid(raw)?))
}

/// Who is in the transcript's call now, the people its live frames go to.
async fn in_call(state: &AppState, transcript: &CallTranscript) -> Vec<UserId> {
    state
        .voice
        .in_call(transcript.channel_id, Listing::Fresh)
        .await
}

async fn add(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    Path((id, raw_mark)): Path<(String, String)>,
    Json(body): Json<PutMarkDto>,
) -> Result<(StatusCode, Json<MarkDto>), ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let (kind, text) = parse_body(&body)?;
    let mark = mark_id(&raw_mark)?;
    let transcript = readable(&state, ctx.user_id, &id, reading()).await?;
    if transcript.ended_at.is_some() {
        return Err(ApiError::Conflict("this call is no longer transcribed"));
    }
    let people = in_call(&state, &transcript).await;
    if !people.contains(&ctx.user_id) {
        return Err(ApiError::ForbiddenBecause("join the call first"));
    }
    let new = NewMark {
        id: mark,
        transcript_id: transcript.id,
        author: ctx.user_id,
        at: now_ms(),
        kind,
        text,
        source: MarkSource::Manual,
        gap_ms: MANUAL_GAP_MS,
    };
    match marks::add(&state, transcript.channel_id, &new, &people).await? {
        PutMark::Created(kept) => Ok((StatusCode::CREATED, Json(MarkDto::from(&kept)))),
        PutMark::Existing(kept) => Ok((StatusCode::OK, Json(MarkDto::from(&kept)))),
        PutMark::IdTaken => Err(ApiError::Conflict("mark id already used")),
        PutMark::Full => Err(ApiError::Conflict(
            "this call has as many marks as it can hold",
        )),
        PutMark::TooSoon(wait_ms) => Err(ApiError::RateLimited {
            retry_after_seconds: u64::try_from(wait_ms).unwrap_or(0).div_ceil(1000).max(1),
        }),
    }
}

async fn remove(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    Path((id, raw_mark)): Path<(String, String)>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let mark_id = mark_id(&raw_mark)?;
    let transcript = readable(&state, ctx.user_id, &id, reading()).await?;
    let missing = ApiError::NotFound("mark not found");
    let mark = state.store.call_transcript_mark(mark_id).await?;
    let Some(mark) = mark.filter(|m| m.transcript_id == transcript.id) else {
        return Err(missing);
    };
    if mark.author_id != ctx.user_id {
        let held = state
            .store
            .permissions_in_channel(ctx.user_id, transcript.channel_id)
            .await?;
        if !held.contains(Permissions::MANAGE_MESSAGES) {
            return Err(ApiError::Forbidden);
        }
    }
    if !state.store.delete_call_transcript_mark(mark.id).await? {
        return Err(missing);
    }
    if transcript.ended_at.is_none() {
        let people = in_call(&state, &transcript).await;
        marks::removed(
            &state,
            transcript.channel_id,
            (transcript.id, mark.id),
            &people,
        );
    }
    Ok(StatusCode::NO_CONTENT)
}
