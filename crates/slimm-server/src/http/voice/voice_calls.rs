// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `GET /channels/{id}/voice/calls`: a voice channel's recent calls, worked
//! out from its recorded events (decision 0066), with what landed on the
//! canvas during each.

use std::collections::HashSet;

use axum::Router;
use axum::extract::{Path, State};
use axum::http::request::Parts;
use axum::routing::get;
use serde::{Deserialize, Serialize};

use super::super::AppState;
use super::super::error::ApiError;
use super::super::extract::{Authed, Json, Query, enforce};
use super::super::messages::parse_uuid;
use crate::call_history::{Call, segment};
use crate::ids::{ChannelId, UserId};
use crate::permissions::Permissions;
use crate::presence::Visibility;
use crate::ratelimit::Class;
use crate::store::{CALL_HISTORY_RETENTION_DAYS, VoiceEvent};
use crate::voice::VoiceError;

const DEFAULT_CALLS: usize = 10;
const MAX_CALLS: usize = 30;

pub fn routes() -> Router<AppState> {
    Router::new().route("/channels/{channel_id}/voice/calls", get(list))
}

#[derive(Deserialize)]
struct ListParams {
    limit: Option<usize>,
}

#[derive(Serialize)]
struct CallsDto {
    retention_days: i64,
    /// Live objects on the channel's canvas now.
    canvas_object_count: i64,
    calls: Vec<CallDto>,
}

#[derive(Serialize)]
struct CallDto {
    /// The transcript the server kept of this call, when the caller may read it.
    #[serde(skip_serializing_if = "Option::is_none")]
    transcript_id: Option<String>,
    started_at: i64,
    /// Null while the call is still going.
    ended_at: Option<i64>,
    events: Vec<EventDto>,
    canvas: Vec<CanvasDto>,
}

#[derive(Serialize)]
struct EventDto {
    at: i64,
    user_id: String,
    kind: &'static str,
}

#[derive(Serialize)]
struct CanvasDto {
    user_id: String,
    kind: String,
    first_at: i64,
    count: i64,
}

async fn list(
    Authed(ctx): Authed,
    parts: Parts,
    Path(channel_id): Path<String>,
    Query(params): Query<ListParams>,
    State(state): State<AppState>,
) -> Result<Json<CallsDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::AuthedRead)?;
    let channel_id = ChannelId(parse_uuid(&channel_id)?);
    let permissions = state
        .store
        .permissions_in_channel(ctx.user_id, channel_id)
        .await?;
    if !permissions.contains(Permissions::VIEW_CHANNEL) {
        return Err(ApiError::Forbidden);
    }
    let limit = params.limit.unwrap_or(DEFAULT_CALLS).clamp(1, MAX_CALLS);

    let all = state.store.voice_events(channel_id).await?;
    let hidden = hidden_from(&state, ctx.user_id, &all).await?;
    let events: Vec<VoiceEvent> = all
        .into_iter()
        .filter(|e| !hidden.contains(&e.user_id))
        .collect();
    let present: HashSet<UserId> = match state.voice.list_participants(channel_id).await {
        Ok(list) => list.into_iter().map(|p| p.user_id).collect(),
        // Without an answer from the SFU, an open call reads as over.
        Err(VoiceError::Unavailable | VoiceError::Internal(_)) => HashSet::new(),
    };

    let transcripts = visible_transcripts(&state, ctx.user_id, channel_id).await?;
    let mut calls = Vec::new();
    for call in segment(&events, &present)
        .into_iter()
        .filter(Call::is_listed)
        .take(limit)
    {
        let end = call.ended_at.unwrap_or_else(crate::store::now_ms);
        let canvas = state
            .store
            .canvas_activity_between(channel_id, call.started_at, end)
            .await?
            .into_iter()
            .filter(|a| !hidden.contains(&a.user_id))
            .map(|a| CanvasDto {
                user_id: a.user_id.to_string(),
                kind: a.kind,
                first_at: a.first_at,
                count: a.count,
            })
            .collect();
        let transcript_id = transcripts
            .iter()
            .find(|(_, at)| *at >= call.started_at && *at <= end)
            .map(|(id, _)| id.to_string());
        calls.push(CallDto {
            transcript_id,
            started_at: call.started_at,
            ended_at: call.ended_at,
            events: call
                .events
                .iter()
                .map(|e| EventDto {
                    at: e.at,
                    user_id: e.user_id.to_string(),
                    kind: e.kind.as_str(),
                })
                .collect(),
            canvas,
        });
    }
    Ok(Json(CallsDto {
        retention_days: CALL_HISTORY_RETENTION_DAYS,
        canvas_object_count: state.store.canvas_object_count(channel_id).await?,
        calls,
    }))
}

/// The `(id, started_at)` of this channel's transcripts, none when the caller may not read them.
async fn visible_transcripts(
    state: &AppState,
    viewer: UserId,
    channel_id: ChannelId,
) -> Result<Vec<(crate::ids::CallTranscriptId, i64)>, ApiError> {
    let held = state
        .store
        .permissions_in_channel(viewer, channel_id)
        .await?;
    if !held.contains(Permissions::VIEW_TRANSCRIPTS) {
        return Ok(Vec::new());
    }
    let since = crate::store::now_ms() - CALL_HISTORY_RETENTION_DAYS * 24 * 60 * 60 * 1000;
    Ok(state
        .store
        .call_transcripts_since(channel_id, since)
        .await?)
}

/// Everyone in this channel's history whose presence is hidden from
/// `viewer`, the same rule the live roster applies.
async fn hidden_from(
    state: &AppState,
    viewer: UserId,
    events: &[VoiceEvent],
) -> Result<HashSet<UserId>, ApiError> {
    let mut people: Vec<UserId> = events
        .iter()
        .map(|e| e.user_id)
        .filter(|&id| id != viewer)
        .collect();
    people.sort();
    people.dedup();
    let visibilities = state.store.presence_visibility_many(&people).await?;
    Ok(people
        .into_iter()
        .filter(|id| visibilities.get(id) == Some(&Visibility::Hidden))
        .collect())
}
