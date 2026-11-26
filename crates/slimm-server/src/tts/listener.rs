// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The listener's `/v1/speak` route as a [`Speaker`].

use std::time::Duration;

use reqwest::StatusCode;

use super::{Dispatch, SpeakError, SpeakFuture, Speaker};
use crate::call_audio::CallAudio;

/// Synthesis, joining the room and the speech itself, so a long line fits with room to spare.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(60);

pub struct ListenerSpeaker {
    http: reqwest::Client,
    url: String,
    secret: String,
}

impl ListenerSpeaker {
    pub fn new(url: String, secret: String) -> Self {
        let http = reqwest::Client::builder()
            .timeout(REQUEST_TIMEOUT)
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .expect("an HTTP client with a timeout builds");
        Self { http, url, secret }
    }

    /// `None` when no listener is configured.
    pub fn of(call_audio: &CallAudio) -> Option<Self> {
        let (url, secret) = call_audio.speak_endpoint()?;
        Some(Self::new(url, secret))
    }
}

impl Speaker for ListenerSpeaker {
    fn available(&self) -> SpeakFuture<'_, bool> {
        Box::pin(async move {
            let probe = self
                .http
                .get(&self.url)
                .bearer_auth(&self.secret)
                .send()
                .await;
            matches!(probe, Ok(response) if response.status() == StatusCode::NO_CONTENT)
        })
    }

    fn speak(&self, dispatch: Dispatch) -> SpeakFuture<'_, Result<(), SpeakError>> {
        Box::pin(async move {
            let body = serde_json::json!({
                "livekit_url": dispatch.livekit_url,
                "token": dispatch.token,
                "text": dispatch.text,
            });
            let response = self
                .http
                .post(&self.url)
                .bearer_auth(&self.secret)
                .json(&body)
                .send()
                .await
                .map_err(|_| SpeakError::Unavailable)?;
            match response.status() {
                StatusCode::NO_CONTENT => Ok(()),
                StatusCode::UNPROCESSABLE_ENTITY => Err(SpeakError::Rejected),
                StatusCode::NOT_IMPLEMENTED | StatusCode::UNAUTHORIZED => {
                    Err(SpeakError::Unavailable)
                }
                _ => Err(SpeakError::Failed),
            }
        })
    }
}
