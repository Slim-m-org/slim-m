// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `POST /v1/speak` (decision 0142): one line of text in, spoken into a call out.
//! The text is synthesised here ([`Synthesizer`]), played into the room the
//! server's token names ([`Stage`]), and dropped; nothing is written or kept.

use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;
use std::time::Duration;

use axum::Json;
use axum::extract::State;
use axum::http::StatusCode;
use serde::Deserialize;

use crate::control::Control;

/// The longest line accepted; the server enforces the same cap before it asks.
pub const MAX_TEXT_CHARS: usize = 300;
/// The longest speech played; a longer synthesis is refused rather than cut.
pub const MAX_SPEECH: Duration = Duration::from_secs(30);

pub type Boxed<'a, T> = Pin<Box<dyn Future<Output = anyhow::Result<T>> + Send + 'a>>;

/// Mono 16-bit speech.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Speech {
    pub samples: Vec<i16>,
    pub sample_rate: u32,
}

impl Speech {
    pub fn duration(&self) -> Duration {
        Duration::from_millis(self.samples.len() as u64 * 1000 / u64::from(self.sample_rate.max(1)))
    }
}

/// Text to speech; Piper in production, a fake in tests.
pub trait Synthesizer: Send + Sync + 'static {
    fn synthesize<'a>(&'a self, text: &'a str) -> Boxed<'a, Speech>;
}

/// Plays speech into a room; LiveKit in production, a fake in tests.
pub trait Stage: Send + Sync + 'static {
    fn perform<'a>(&'a self, url: &'a str, token: &'a str, speech: &'a Speech) -> Boxed<'a, ()>;
}

/// What a listener with speech configured holds.
pub struct Speaker {
    pub synthesizer: Arc<dyn Synthesizer>,
    pub stage: Arc<dyn Stage>,
}

#[derive(Deserialize)]
pub struct Request {
    livekit_url: String,
    token: String,
    text: String,
}

/// Collapses whitespace so one request is one line for the synthesizer.
fn one_line(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// `GET /v1/speak`: 204 when a voice is set up, 501 when not.
pub async fn status(State(control): State<Control>) -> StatusCode {
    match control.speaker() {
        Some(_) => StatusCode::NO_CONTENT,
        None => StatusCode::NOT_IMPLEMENTED,
    }
}

pub async fn handler(
    State(control): State<Control>,
    Json(request): Json<Request>,
) -> Result<StatusCode, StatusCode> {
    let speaker = control.speaker().ok_or(StatusCode::NOT_IMPLEMENTED)?;
    let text = one_line(&request.text);
    if text.is_empty() || text.chars().count() > MAX_TEXT_CHARS {
        return Err(StatusCode::UNPROCESSABLE_ENTITY);
    }
    let _turn = control
        .speech_turn()
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    let speech = speaker.synthesizer.synthesize(&text).await.map_err(|why| {
        tracing::warn!(%why, "the synthesizer failed");
        StatusCode::INTERNAL_SERVER_ERROR
    })?;
    if speech.samples.is_empty() || speech.duration() > MAX_SPEECH {
        return Err(StatusCode::UNPROCESSABLE_ENTITY);
    }
    speaker
        .stage
        .perform(&request.livekit_url, &request.token, &speech)
        .await
        .map_err(|why| {
            tracing::warn!(%why, "could not speak into the room");
            StatusCode::BAD_GATEWAY
        })?;
    Ok(StatusCode::NO_CONTENT)
}

#[cfg(test)]
mod tests;
