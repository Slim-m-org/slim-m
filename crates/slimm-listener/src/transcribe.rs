// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `POST /v1/transcribe`: one stored voice message in, its text out. The bytes
//! are decoded here ([`crate::clip`]), run through the same engine pool the
//! calls use, and dropped; nothing is written or kept.

use axum::Json;
use axum::body::Bytes;
use axum::extract::{Query, Request, State};
use axum::http::StatusCode;
use axum::middleware::Next;
use axum::response::{IntoResponse, Response};
use serde::{Deserialize, Serialize};

use crate::clip;
use crate::control::{Control, has_secret};
use crate::endpoint::SAMPLE_RATE;
use crate::stt::{Meta, Work, is_noise_marker};

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

/// Turns away a caller without the secret before [`handler`]'s extractors read the body.
pub async fn require_secret(
    State(control): State<Control>,
    request: Request,
    next: Next,
) -> Response {
    if !has_secret(request.headers(), &control.config().secret) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    next.run(request).await
}

pub async fn handler(
    State(control): State<Control>,
    Query(params): Query<Params>,
    body: Bytes,
) -> Result<Json<Reply>, StatusCode> {
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
    let text = if is_noise_marker(&transcript.text) {
        String::new()
    } else {
        transcript.text
    };
    Ok(Json(Reply {
        text,
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

    /// Hears the same words in every clip.
    struct Saying(&'static str);
    impl Transcriber for Saying {
        fn transcribe(&self, _: &[i16], _: Option<&str>) -> anyhow::Result<Transcript> {
            Ok(Transcript {
                text: self.0.into(),
                language: None,
            })
        }
        fn model(&self) -> String {
            "saying".into()
        }
    }

    fn router() -> axum::Router {
        router_hearing(Arc::new(Counting))
    }

    fn router_hearing(transcriber: Arc<dyn Transcriber>) -> axum::Router {
        let config = Arc::new(Config {
            listen: "127.0.0.1:0".parse().unwrap(),
            secret: SECRET.into(),
            model: "m".into(),
            language: Some("en".into()),
            threads: 1,
            max_sessions: 1,
        });
        let pool = Arc::new(Pool::new(transcriber, 1));
        Control::new(config, pool, Arc::new(NoSessions)).router()
    }

    async fn post(secret: &str, body: &[u8]) -> (StatusCode, serde_json::Value) {
        post_to(router(), secret, body).await
    }

    async fn post_to(
        router: axum::Router,
        secret: &str,
        body: &[u8],
    ) -> (StatusCode, serde_json::Value) {
        let request = Request::post("/v1/transcribe")
            .header("authorization", format!("Bearer {secret}"))
            .body(Body::from(body.to_vec()))
            .unwrap();
        let response = router.oneshot(request).await.unwrap();
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

    #[tokio::test]
    async fn a_caller_without_the_secret_is_refused_before_the_body_is_read() {
        for authorization in [Some("Bearer wrong"), None] {
            let mut request = Request::post("/v1/transcribe");
            if let Some(value) = authorization {
                request = request.header("authorization", value);
            }
            let endless = futures_util::stream::pending::<Result<Bytes, std::io::Error>>();
            let request = request.body(Body::from_stream(endless)).unwrap();
            let response =
                tokio::time::timeout(std::time::Duration::from_secs(5), router().oneshot(request))
                    .await
                    .expect("answered without waiting for the body")
                    .unwrap();
            assert_eq!(
                response.status(),
                StatusCode::UNAUTHORIZED,
                "{authorization:?}"
            );
        }
    }

    #[tokio::test]
    async fn a_body_over_the_limit_is_refused() {
        let (status, _) = post(SECRET, &vec![0; MAX_BODY_BYTES + 1]).await;
        assert_eq!(status, StatusCode::PAYLOAD_TOO_LARGE);
    }

    #[tokio::test]
    async fn a_clip_of_only_noise_markers_has_no_words() {
        for marker in ["[BLANK_AUDIO]", "(music)", "[Music] (applause)"] {
            let (status, reply) =
                post_to(router_hearing(Arc::new(Saying(marker))), SECRET, OGG).await;
            assert_eq!(status, StatusCode::OK);
            assert_eq!(reply["text"], "", "{marker}");
        }
        let speech = "[BLANK_AUDIO] call me back [BLANK_AUDIO]";
        let (_, reply) = post_to(router_hearing(Arc::new(Saying(speech))), SECRET, OGG).await;
        assert_eq!(reply["text"], speech, "words between markers are kept");
    }
}
