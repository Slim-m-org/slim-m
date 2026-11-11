// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Reading, deleting and searching the call transcripts the server keeps
//! (decision 0113). A reader needs `VIEW_CHANNEL` and `VIEW_TRANSCRIPTS` on the
//! transcript's channel at read time, whether or not they were in the call.

use axum::Router;
use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::http::request::Parts;
use axum::routing::get;
use serde::{Deserialize, Serialize};

use super::super::AppState;
use super::super::error::ApiError;
use super::super::extract::{AUTHED_READ, Authed, AuthedLimited, Json, Query, enforce};
use super::super::messages::parse_uuid;
use crate::ids::{CallTranscriptId, ChannelId, UserId};
use crate::limits::MAX_QUERY_CHARS;
use crate::permissions::Permissions;
use crate::ratelimit::Class;
use crate::store::{SearchError, TranscriptLine};

const DEFAULT_LINES: i64 = 200;
const MAX_LINES: i64 = 500;
const DEFAULT_HITS: i64 = 50;
const MAX_HITS: i64 = 100;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route(
            "/voice/transcripts/{transcript_id}",
            get(show).delete(remove),
        )
        .route("/search/transcripts", get(search))
}

#[derive(Serialize)]
struct LineDto {
    seq: i64,
    speaker_id: String,
    at: i64,
    text: String,
}

impl From<TranscriptLine> for LineDto {
    fn from(line: TranscriptLine) -> Self {
        Self {
            seq: line.seq,
            speaker_id: line.speaker_id.to_string(),
            at: line.at,
            text: line.text,
        }
    }
}

#[derive(Serialize)]
struct TranscriptDto {
    id: String,
    channel_id: String,
    started_at: i64,
    ended_at: Option<i64>,
    mode: String,
    lines: Vec<LineDto>,
    /// The `seq` to pass as `after_seq` for the next page; null on the last page.
    next_after_seq: Option<i64>,
}

#[derive(Deserialize)]
struct PageParams {
    after_seq: Option<i64>,
    limit: Option<i64>,
}

#[derive(Serialize)]
struct HitDto {
    transcript_id: String,
    channel_id: String,
    seq: i64,
    speaker_id: String,
    at: i64,
    text: String,
    /// `text` with each match between U+E000 and U+E001.
    highlight: String,
}

#[derive(Deserialize)]
struct SearchParams {
    q: Option<String>,
    before: Option<i64>,
    limit: Option<i64>,
}

/// The transcript's channel, when the caller may see it at all; the same 404 for a missing row.
async fn readable(
    state: &AppState,
    user: UserId,
    raw: &str,
    needs: Permissions,
) -> Result<crate::store::CallTranscript, ApiError> {
    let id = CallTranscriptId(parse_uuid(raw)?);
    let missing = ApiError::NotFound("transcript not found");
    let transcript = state.store.call_transcript(id).await?.ok_or(missing)?;
    let held = state
        .store
        .permissions_in_channel(user, transcript.channel_id)
        .await?;
    if !held.contains(needs) {
        return Err(ApiError::NotFound("transcript not found"));
    }
    Ok(transcript)
}

async fn show(
    AuthedLimited(ctx): AuthedLimited<AUTHED_READ>,
    Path(id): Path<String>,
    Query(params): Query<PageParams>,
    State(state): State<AppState>,
) -> Result<Json<TranscriptDto>, ApiError> {
    let needs = Permissions::VIEW_CHANNEL.union(Permissions::VIEW_TRANSCRIPTS);
    let transcript = readable(&state, ctx.user_id, &id, needs).await?;
    let limit = params.limit.unwrap_or(DEFAULT_LINES).clamp(1, MAX_LINES);
    let mut lines = state
        .store
        .call_transcript_lines(transcript.id, params.after_seq.unwrap_or(0), limit + 1)
        .await?;
    let more = usize::try_from(limit).is_ok_and(|n| lines.len() > n);
    if more {
        lines.pop();
    }
    let next_after_seq = more.then(|| lines.last().map(|l| l.seq)).flatten();
    Ok(Json(TranscriptDto {
        id: transcript.id.to_string(),
        channel_id: transcript.channel_id.to_string(),
        started_at: transcript.started_at,
        ended_at: transcript.ended_at,
        mode: transcript.mode,
        lines: lines.into_iter().map(LineDto::from).collect(),
        next_after_seq,
    }))
}

async fn remove(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    Path(id): Path<String>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let transcript = readable(&state, ctx.user_id, &id, Permissions::VIEW_CHANNEL).await?;
    let held = state
        .store
        .permissions_in_channel(ctx.user_id, transcript.channel_id)
        .await?;
    if !held.contains(Permissions::MANAGE_MESSAGES) {
        return Err(ApiError::Forbidden);
    }
    state.store.delete_call_transcript(transcript.id).await?;
    Ok(StatusCode::NO_CONTENT)
}

/// Every channel the caller may read a transcript in, never one they may not.
async fn readable_channels(state: &AppState, user: UserId) -> Result<Vec<ChannelId>, ApiError> {
    let visible: Vec<ChannelId> = state
        .store
        .visible_channels(user)
        .await?
        .into_iter()
        .map(|c| c.id)
        .collect();
    let needs = Permissions::VIEW_CHANNEL.union(Permissions::VIEW_TRANSCRIPTS);
    let held = state.store.permissions_in_channels(user, &visible).await?;
    Ok(visible
        .into_iter()
        .filter(|id| held.get(id).is_some_and(|p| p.contains(needs)))
        .collect())
}

async fn search(
    AuthedLimited(ctx): AuthedLimited<AUTHED_READ>,
    Query(params): Query<SearchParams>,
    State(state): State<AppState>,
) -> Result<Json<Vec<HitDto>>, ApiError> {
    let q = params.q.as_deref().map(str::trim).unwrap_or_default();
    if q.is_empty() {
        return Err(ApiError::BadRequest("search query must not be empty"));
    }
    if q.chars().count() > MAX_QUERY_CHARS {
        return Err(ApiError::BadRequest("search query is too long"));
    }
    let limit = params.limit.unwrap_or(DEFAULT_HITS).clamp(1, MAX_HITS);
    let fts = match state.store.fts_query_for(q).await {
        Ok(Some(fts)) => fts,
        Ok(None) => return Ok(Json(Vec::new())),
        Err(SearchError::Internal(e)) => return Err(e.into()),
        Err(_) => return Err(ApiError::BadRequest("that search query is not valid")),
    };
    let channels = readable_channels(&state, ctx.user_id).await?;
    let hits = match state
        .store
        .search_call_transcripts(&channels, &fts, params.before, limit)
        .await
    {
        Ok(hits) => hits,
        Err(SearchError::Internal(e)) => return Err(e.into()),
        Err(_) => return Err(ApiError::BadRequest("that search query is not valid")),
    };
    Ok(Json(
        hits.into_iter()
            .map(|h| HitDto {
                transcript_id: h.transcript_id.to_string(),
                channel_id: h.channel_id.to_string(),
                seq: h.line.seq,
                speaker_id: h.line.speaker_id.to_string(),
                at: h.line.at,
                text: h.line.text,
                highlight: h.highlight,
            })
            .collect(),
    ))
}
