// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Speaking a line into a call (decision 0142). The route checks the caller may
//! speak in the call and are in it, then queues the line; the listener says it
//! as a participant named "<name> (TTS)". The text reaching the call chat is
//! the client's own ordinary send, made once this route has accepted the line.

use axum::Router;
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::StatusCode;
use axum::routing::post;
use serde::{Deserialize, Serialize};

use super::super::AppState;
use super::super::error::ApiError;
use super::super::extract::{Json, TTS};
use super::super::messages::parse_uuid;
use super::super::participant::Participant;
use crate::ids::ChannelId;
use crate::permissions::Permissions;
use crate::tts::{Line, MAX_TEXT_CHARS, Refusal};
use crate::voice::Listing;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/channels/{channel_id}/voice/tts", post(speak))
        .layer(DefaultBodyLimit::max(BODY_LIMIT))
}

/// A line is 300 characters; this leaves room for multi-byte text and the JSON around it.
const BODY_LIMIT: usize = 4 * 1024;

#[derive(Deserialize)]
struct SpeakRequest {
    text: String,
}

#[derive(Serialize)]
struct Queued {
    /// How many lines are ahead of this one in the call.
    ahead: usize,
}

async fn speak(
    Participant(ctx): Participant<TTS>,
    Path(channel_id): Path<String>,
    State(state): State<AppState>,
    Json(req): Json<SpeakRequest>,
) -> Result<(StatusCode, Json<Queued>), ApiError> {
    let channel_id = ChannelId(parse_uuid(&channel_id)?);
    let needed = Permissions::VIEW_CHANNEL
        .union(Permissions::CONNECT)
        .union(Permissions::SEND_MESSAGES)
        .union(Permissions::SPEAK);
    super::super::write_refusal::require(&state, ctx.user_id, channel_id, needed).await?;

    let text = req.text.split_whitespace().collect::<Vec<_>>().join(" ");
    if text.is_empty() {
        return Err(ApiError::BadRequest("say something to speak"));
    }
    if text.chars().count() > MAX_TEXT_CHARS {
        return Err(ApiError::BadRequest(
            "a spoken line is at most 300 characters",
        ));
    }
    let present = state.voice.in_call(channel_id, Listing::Shared).await;
    if !present.contains(&ctx.user_id) {
        return Err(ApiError::ForbiddenBecause(
            "join the call to use text to speech",
        ));
    }
    let name = state
        .store
        .user_profile(ctx.user_id)
        .await?
        .map(|u| u.display_name)
        .unwrap_or_else(|| "someone".to_owned());
    let line = Line {
        channel_id,
        user_id: ctx.user_id,
        name,
        text,
    };
    match state.tts.enqueue(line).await {
        Ok(ahead) => Ok((StatusCode::ACCEPTED, Json(Queued { ahead }))),
        Err(Refusal::Disabled | Refusal::Unavailable) => Err(ApiError::NotConfigured(
            "text to speech is not set up on this server",
        )),
        Err(Refusal::Full) => Err(ApiError::TooManyRequests),
    }
}
