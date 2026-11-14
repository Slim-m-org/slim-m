// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `POST /v1/transcribe`: one stored voice message in, its text out. The bytes
//! are decoded here ([`crate::clip`]), run through the same engine pool the
//! calls use, and dropped; nothing is written or kept.

use axum::Json;
use axum::body::Bytes;
use axum::extract::{Query, State};
use axum::http::{HeaderMap, StatusCode, header};
use serde::{Deserialize, Serialize};

use crate::clip;
use crate::control::{Control, same_secret};
use crate::endpoint::SAMPLE_RATE;
use crate::stt::{Meta, Work};

/// A clip of the longest length in WAV is about 11 MB; this leaves room.
pub const MAX_BODY_BYTES: usize = 24 * 1024 * 1024;

#[derive(Deserialize)]
pub struct Params {
    language: Option<String>,
}

#[derive(Serialize)]
pub struct Reply {
    pub text: String,
    pub language: Option<String>,
    pub duration_ms: i64,
}

pub async fn handler(
    State(control): State<Control>,
    headers: HeaderMap,
    Query(params): Query<Params>,
    body: Bytes,
) -> Result<Json<Reply>, StatusCode> {
    let presented = headers
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .unwrap_or_default();
    if !same_secret(presented, &control.config().secret) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let pcm = tokio::task::spawn_blocking(move || clip::decode(&body))
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?
        .map_err(|why| {
            tracing::warn!(%why, "refusing a clip to transcribe");
            StatusCode::UNPROCESSABLE_ENTITY
        })?;
    let duration_ms = (pcm.len() * 1000 / SAMPLE_RATE) as i64;
    let (reply, mut done) = tokio::sync::mpsc::unbounded_channel();
    control.pool().submit(Work {
        meta: Meta {
            session: "clip".into(),
            identity: String::new(),
            start_ms: 0,
            end_ms: duration_ms,
        },
        pcm,
        language: params
            .language
            .or_else(|| control.config().language.clone()),
        reply,
    });
    let finished = done.recv().await.ok_or(StatusCode::INTERNAL_SERVER_ERROR)?;
    let transcript = finished.result.map_err(|why| {
        tracing::warn!(%why, "the engine failed on a clip");
        StatusCode::INTERNAL_SERVER_ERROR
    })?;
    Ok(Json(Reply {
        text: transcript.text,
        language: transcript.language,
        duration_ms,
    }))
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use axum::body::{Body, to_bytes};
    use axum::http::Request;
    use tower::ServiceExt;

    use super::*;
    use crate::config::Config;
    use crate::control::{Launch, Launcher, Running};
    use crate::stt::{Pool, Transcriber, Transcript};

    const SECRET: &str = "0123456789abcdef0123456789abcdef";
    const OGG: &[u8] = include_bytes!("../tests/fixtures/tone.ogg");
    const WAV: &[u8] = include_bytes!("../tests/fixtures/tone-8k-stereo.wav");

    /// Says how many samples it was given, so the decode is what the test sees.
    struct Counting;
    impl Transcriber for Counting {
        fn transcribe(&self, pcm: &[i16], language: Option<&str>) -> anyhow::Result<Transcript> {
            Ok(Transcript {
                text: format!("{} samples", pcm.len()),
                language: language.map(str::to_owned),
            })
        }
        fn model(&self) -> String {
            "counting".into()
        }
    }

    struct NoSessions;
    impl Launcher for NoSessions {
        fn launch(&self, _: Launch) -> Running {
            unreachable!("a transcribe request starts no session")
        }
    }

    fn router() -> axum::Router {
        let config = Arc::new(Config {
            listen: "127.0.0.1:0".parse().unwrap(),
            secret: SECRET.into(),
            model: "m".into(),
            language: Some("en".into()),
            threads: 1,
            max_sessions: 1,
        });
        let pool = Arc::new(Pool::new(Arc::new(Counting), 1));
        Control::new(config, pool, Arc::new(NoSessions)).router()
    }

    async fn post(secret: &str, body: &[u8]) -> (StatusCode, serde_json::Value) {
        let request = Request::post("/v1/transcribe")
            .header("authorization", format!("Bearer {secret}"))
            .body(Body::from(body.to_vec()))
            .unwrap();
        let response = router().oneshot(request).await.unwrap();
        let status = response.status();
        let bytes = to_bytes(response.into_body(), usize::MAX).await.unwrap();
        (status, serde_json::from_slice(&bytes).unwrap_or_default())
    }

    #[tokio::test]
    async fn an_ogg_opus_clip_is_decoded_and_transcribed() {
        let (status, reply) = post(SECRET, OGG).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(reply["language"], "en");
        let duration = reply["duration_ms"].as_i64().unwrap();
        assert!((duration - 500).abs() < 60, "{duration}");
        assert!(reply["text"].as_str().unwrap().ends_with(" samples"));
    }

    #[tokio::test]
    async fn a_wav_clip_is_decoded_and_transcribed() {
        let (status, reply) = post(SECRET, WAV).await;
        assert_eq!(status, StatusCode::OK);
        let duration = reply["duration_ms"].as_i64().unwrap();
        assert!((duration - 250).abs() < 60, "{duration}");
    }

    #[tokio::test]
    async fn the_wrong_secret_and_a_non_audio_body_are_refused() {
        assert_eq!(post("wrong", OGG).await.0, StatusCode::UNAUTHORIZED);
        assert_eq!(
            post(SECRET, b"not audio").await.0,
            StatusCode::UNPROCESSABLE_ENTITY
        );
    }
}
