// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The server asking to transcribe a call, and the once-only notice that a
//! Space transcribes every call (decision 0113). Answering and stopping reuse
//! the call-audio routes; the session machine is the same one a module uses.

use axum::Router;
use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::http::request::Parts;
use axum::routing::{get, post};
use serde::Serialize;

use super::super::AppState;
use super::super::error::ApiError;
use super::super::extract::{Authed, Json, enforce};
use super::voice_call_audio::{
    CallAudioDto, people_in_call, request_error, visible_view, voice_channel,
};
use crate::call_audio::{RequestError, runtime, transcript};
use crate::ids::{ChannelId, UserId};
use crate::ratelimit::Class;
use crate::store::{TranscriptionMode, now_ms};

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/channels/{channel_id}/voice/transcript", post(ask))
        .route("/voice/transcription-notice", get(notice))
        .route("/voice/transcription-notice/ack", post(acknowledge))
}

#[derive(Serialize)]
struct NoticeDto {
    mode: &'static str,
    acknowledged: bool,
}

async fn ask(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    Path(channel): Path<String>,
) -> Result<Json<CallAudioDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let channel = voice_channel(&state, ctx.user_id, &channel).await?;
    if !state.call_audio.is_enabled() {
        return Err(ApiError::NotConfigured(
            "this server has no call audio listener",
        ));
    }
    if state.store.call_transcription().await? != TranscriptionMode::OnRequest {
        return Err(ApiError::Conflict(
            "this Space does not transcribe calls on request",
        ));
    }
    let people = people_in_call(&state, channel).await;
    if !people.contains(&ctx.user_id) {
        return Err(ApiError::ForbiddenBecause("join the call first"));
    }
    let began = state
        .call_audio
        .begin(
            (channel, transcript::subject()),
            ctx.user_id,
            &people,
            now_ms(),
        )
        .map_err(request_error)?;
    let view = visible_view(&state, ctx.user_id, &began).await;
    if !runtime::apply(&state, began).await {
        return Err(ApiError::Unavailable);
    }
    Ok(Json(CallAudioDto::of_session(view)))
}

/// Starts the `always` session when someone joins a call nobody is being heard in.
pub(super) async fn ensure_always(state: &AppState, channel: ChannelId, joiner: UserId) {
    match state.store.call_transcription().await {
        Ok(TranscriptionMode::Always) => {}
        Ok(_) => return,
        Err(err) => {
            tracing::warn!(%err, "could not read the transcription mode");
            return;
        }
    }
    if !is_community_voice(state, channel).await {
        return;
    }
    let mut present = people_in_call(state, channel).await;
    if !present.contains(&joiner) {
        present.push(joiner);
    }
    let begun = state
        .call_audio
        .begin_always((channel, transcript::subject()), &present, now_ms());
    match begun {
        Ok(outcome) => {
            runtime::apply(state, outcome).await;
        }
        Err(RequestError::AlreadyOn) => {
            if let Some(outcome) = state.call_audio.joined(channel, joiner, now_ms()) {
                runtime::apply(state, outcome).await;
            }
        }
        Err(err) => tracing::debug!(?err, "the call is not being transcribed"),
    }
}

/// A direct message call is never transcribed; only a community voice channel is.
async fn is_community_voice(state: &AppState, channel: ChannelId) -> bool {
    matches!(
        state.store.channel(channel).await,
        Ok(Some(c)) if c.kind == "voice" && c.parent_message_id.is_none()
    )
}

async fn notice(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
) -> Result<Json<NoticeDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::AuthedRead)?;
    Ok(Json(NoticeDto {
        mode: state.store.call_transcription().await?.as_str(),
        acknowledged: state
            .store
            .transcription_notice_acknowledged_at(ctx.user_id)
            .await?
            .is_some(),
    }))
}

async fn acknowledge(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    state
        .store
        .acknowledge_transcription_notice(ctx.user_id)
        .await?;
    Ok(StatusCode::NO_CONTENT)
}
