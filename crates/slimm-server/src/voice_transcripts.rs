// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Background transcription of voice messages, for the Spaces that turned it on.
//!
//! The server never decodes audio: the stored bytes go to the speech listener,
//! which already runs the engine for call transcripts (decision 0113), and the
//! text comes back. One clip at a time, newest first, so a busy Space cannot
//! starve the listener's calls. A listener that cannot be reached is retried
//! with the same growing backoff attachment text uses; a clip it refuses is
//! marked failed and not tried again. Encrypted messages are never offered.

use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;
use std::time::Duration;

use tokio::io::AsyncReadExt;

use crate::attachment_text::retry::Retries;
use crate::call_audio::CallAudio;
use crate::hub::{Event, Hub, MessageEvent};
use crate::media::Media;
use crate::state::AppState;
use crate::store::{Store, VoiceCandidate};

const SWEEP_INTERVAL: Duration = Duration::from_secs(10);
const BATCH: i64 = 5;
const MAX_PER_PASS: usize = 20;
const RETRY_BACKOFF: Duration = Duration::from_secs(30);
/// Longer than a clip at the cap takes on a slow host.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(15 * 60);
/// A five minute WAV is about 10 MB; this leaves room.
const MAX_CLIP_BYTES: u64 = 24 * 1024 * 1024;

/// What the engine heard.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Heard {
    pub text: String,
    pub language: Option<String>,
}

/// Why a clip has no text.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Failure {
    /// The engine could not be reached or was busy; try again later.
    Transient,
    /// The engine refused this clip; trying again would not help.
    Permanent,
}

pub type EngineFuture<'a> = Pin<Box<dyn Future<Output = Result<Heard, Failure>> + Send + 'a>>;

/// Speech to text on stored bytes, behind a trait so tests need no listener.
pub trait SpeechEngine: Send + Sync {
    fn transcribe(&self, bytes: Vec<u8>) -> EngineFuture<'_>;
}

/// The speech listener over its `/v1/transcribe` route.
pub struct ListenerEngine {
    http: reqwest::Client,
    url: String,
    secret: String,
}

impl ListenerEngine {
    pub fn new(url: String, secret: String) -> Self {
        let http = reqwest::Client::builder()
            .timeout(REQUEST_TIMEOUT)
            .build()
            .expect("an HTTP client with a timeout builds");
        Self { http, url, secret }
    }

    /// `None` when no listener is configured.
    pub fn of(call_audio: &CallAudio) -> Option<Self> {
        let (url, secret) = call_audio.transcribe_endpoint()?;
        Some(Self::new(url, secret))
    }
}

#[derive(serde::Deserialize)]
struct ListenerReply {
    text: String,
    language: Option<String>,
}

impl SpeechEngine for ListenerEngine {
    fn transcribe(&self, bytes: Vec<u8>) -> EngineFuture<'_> {
        Box::pin(async move {
            let response = self
                .http
                .post(&self.url)
                .bearer_auth(&self.secret)
                .body(bytes)
                .send()
                .await
                .map_err(|_| Failure::Transient)?;
            let status = response.status();
            if status == reqwest::StatusCode::UNPROCESSABLE_ENTITY {
                return Err(Failure::Permanent);
            }
            if !status.is_success() {
                return Err(Failure::Transient);
            }
            let reply: ListenerReply = response.json().await.map_err(|_| Failure::Transient)?;
            Ok(Heard {
                text: reply.text.trim().to_owned(),
                language: reply.language,
            })
        })
    }
}

/// The sweep's state: which clips are backing off.
pub struct VoiceTranscriber {
    retries: Retries,
}

impl VoiceTranscriber {
    pub fn new() -> Self {
        Self::with_backoff(RETRY_BACKOFF)
    }

    pub fn with_backoff(backoff: Duration) -> Self {
        Self {
            retries: Retries::new(backoff),
        }
    }

    /// One pass: transcribes a bounded number of waiting clips and returns how many it settled.
    pub async fn run_pass(
        &self,
        store: &Store,
        media: &Media,
        hub: &Hub,
        engine: &dyn SpeechEngine,
    ) -> usize {
        match store.transcribe_voice_messages().await {
            Ok(true) => {}
            Ok(false) => return 0,
            Err(err) => {
                tracing::warn!(error = %err, "voice transcript setting lookup failed");
                return 0;
            }
        }
        let (mut attempted, mut done) = (0, 0);
        while attempted < MAX_PER_PASS {
            let batch = match store
                .voice_awaiting_transcript(BATCH, &self.retries.waiting())
                .await
            {
                Ok(batch) if !batch.is_empty() => batch,
                Ok(_) => break,
                Err(err) => {
                    tracing::warn!(error = %err, "voice transcript lookup failed");
                    break;
                }
            };
            for candidate in batch {
                if self.process(store, media, hub, engine, &candidate).await {
                    done += 1;
                }
                attempted += 1;
            }
        }
        done
    }

    async fn process(
        &self,
        store: &Store,
        media: &Media,
        hub: &Hub,
        engine: &dyn SpeechEngine,
        candidate: &VoiceCandidate,
    ) -> bool {
        let Some(bytes) = read_clip(media, candidate).await else {
            self.retries.failed(&candidate.sha256);
            return false;
        };
        if let Err(err) = store.begin_voice_transcript(&candidate.sha256).await {
            tracing::warn!(error = %err, attachment = %candidate.hex, "could not mark a voice message pending");
            return false;
        }
        announce(store, hub, candidate, "pending", "").await;
        let outcome = match engine.transcribe(bytes).await {
            Ok(heard) => Ok(heard),
            Err(Failure::Transient) => {
                self.retries.failed(&candidate.sha256);
                return false;
            }
            Err(Failure::Permanent) => Err(()),
        };
        self.retries.settled(&candidate.sha256);
        let finish = match &outcome {
            Ok(heard) => Ok((heard.text.as_str(), heard.language.as_deref())),
            Err(()) => Err(()),
        };
        match store
            .finish_voice_transcript(&candidate.sha256, finish)
            .await
        {
            Ok(Some(done)) => {
                announce(store, hub, candidate, done.status.as_str(), &done.text).await;
            }
            Ok(None) => {}
            Err(err) => {
                tracing::warn!(error = %err, attachment = %candidate.hex, "could not store a voice transcript");
            }
        }
        true
    }
}

impl Default for VoiceTranscriber {
    fn default() -> Self {
        Self::new()
    }
}

async fn read_clip(media: &Media, candidate: &VoiceCandidate) -> Option<Vec<u8>> {
    if candidate.size as u64 > MAX_CLIP_BYTES {
        return None;
    }
    let (file, _) = media.open_attachment(&candidate.hex).await.ok()?;
    let mut bytes = Vec::new();
    file.take(MAX_CLIP_BYTES)
        .read_to_end(&mut bytes)
        .await
        .ok()?;
    Some(bytes)
}

/// Tells everyone who can see a message carrying the clip, so the line under it updates.
async fn announce(
    store: &Store,
    hub: &Hub,
    candidate: &VoiceCandidate,
    status: &'static str,
    text: &str,
) {
    let Ok(messages) = store.messages_with_attachment(&candidate.sha256).await else {
        return;
    };
    for (channel_id, message_id) in messages {
        hub.publish(Event::Message(MessageEvent::VoiceTranscript {
            channel_id,
            message_id,
            attachment_id: candidate.hex.clone(),
            status,
            text: text.to_owned(),
        }));
    }
}

pub(crate) fn spawn_voice_transcript_sweep(state: AppState) {
    let transcriber = Arc::new(VoiceTranscriber::new());
    crate::sweeps::spawn_sweep(SWEEP_INTERVAL, move || {
        let (state, transcriber) = (state.clone(), transcriber.clone());
        async move {
            let Some(engine) = ListenerEngine::of(&state.call_audio) else {
                return;
            };
            transcriber
                .run_pass(&state.store, &state.media, &state.hub, &engine)
                .await;
        }
    });
}

#[cfg(test)]
mod tests {
    use axum::Router;
    use axum::http::{HeaderMap, StatusCode};
    use axum::routing::post;

    use super::*;

    async fn stub(handler: axum::routing::MethodRouter) -> String {
        let app = Router::new().route("/v1/transcribe", handler);
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move { axum::serve(listener, app).await });
        format!("http://{addr}/v1/transcribe")
    }

    #[tokio::test]
    async fn the_listener_engine_sends_the_bytes_with_the_secret_and_reads_the_text() {
        let url = stub(post(
            |headers: HeaderMap, body: axum::body::Bytes| async move {
                assert_eq!(headers["authorization"], "Bearer s3cret");
                assert_eq!(&body[..], b"clip");
                axum::Json(
                    serde_json::json!({"text": " hi there ", "language": "en", "duration_ms": 1}),
                )
            },
        ))
        .await;
        let heard = ListenerEngine::new(url, "s3cret".into())
            .transcribe(b"clip".to_vec())
            .await
            .unwrap();
        assert_eq!(heard.text, "hi there");
        assert_eq!(heard.language.as_deref(), Some("en"));
    }

    #[tokio::test]
    async fn a_refused_clip_is_permanent_and_everything_else_is_transient() {
        let refused = stub(post(|| async { StatusCode::UNPROCESSABLE_ENTITY })).await;
        let broken = stub(post(|| async { StatusCode::INTERNAL_SERVER_ERROR })).await;
        let engine = |url: String| ListenerEngine::new(url, "s".into());
        assert_eq!(
            engine(refused).transcribe(vec![1]).await,
            Err(Failure::Permanent)
        );
        assert_eq!(
            engine(broken).transcribe(vec![1]).await,
            Err(Failure::Transient)
        );
        let gone = "http://127.0.0.1:1/v1/transcribe".to_owned();
        assert_eq!(
            engine(gone).transcribe(vec![1]).await,
            Err(Failure::Transient)
        );
    }

    #[tokio::test]
    async fn the_transcribe_address_follows_the_control_address() {
        let settings = |url: &str| crate::config::ListenerSettings {
            url: url.into(),
            secret: "x".repeat(32),
            livekit_url: None,
        };
        let secure = CallAudio::new(Some(settings("wss://listener.internal:9400/v1/control")));
        assert_eq!(
            secure.transcribe_endpoint().unwrap().0,
            "https://listener.internal:9400/v1/transcribe"
        );
        let plain = CallAudio::new(Some(settings("ws://127.0.0.1:9400")));
        assert_eq!(
            plain.transcribe_endpoint().unwrap().0,
            "http://127.0.0.1:9400/v1/transcribe"
        );
        assert!(CallAudio::disabled().transcribe_endpoint().is_none());
    }
}
