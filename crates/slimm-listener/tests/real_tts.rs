// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `/v1/speak` against a real `livekit-server --dev` and a real Piper voice: a
//! listener with speech on is asked to say a line, and a second participant in
//! the room hears the labelled TTS participant say it.
//!
//! Opt in with `LISTENER_REAL_LIVEKIT=ws://127.0.0.1:7880`, `LISTENER_TEST_PIPER_BIN`
//! (the `piper` executable) and `LISTENER_TEST_PIPER_MODEL` (a voice `.onnx` with its
//! `.onnx.json` beside it). Without them the test passes at once.
#![cfg(feature = "livekit-room")]

use std::sync::Arc;
use std::time::Duration;

use axum::body::Body;
use axum::http::Request;
use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD as B64;
use hmac::{Hmac, Mac};
use sha2::Sha256;
use slimm_listener::config::Config;
use slimm_listener::control::{Control, Launch, Launcher, Running};
use slimm_listener::piper::Piper;
use slimm_listener::room::{LiveKitRoom, RoomEvent as Seen, RoomSource};
use slimm_listener::speak::Speaker;
use slimm_listener::stage::LiveKitStage;
use slimm_listener::stt::{Pool, Transcriber, Transcript};
use tower::ServiceExt;

const KEY: &str = "devkey";
const SECRET: &str = "secret";
const ROOM: &str = "listener-tts-test";
const LISTENER_SECRET: &str = "0123456789abcdef0123456789abcdef";
const LINE: &str = "Hello from the text to speech command";

fn token(identity: &str, name: &str, can_publish: bool) -> String {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs();
    let claims = serde_json::json!({
        "iss": KEY, "sub": identity, "name": name, "nbf": now, "exp": now + 600,
        "video": {"room": ROOM, "roomJoin": true, "canSubscribe": true,
            "canPublish": can_publish, "canPublishData": false},
    });
    let header = B64.encode(r#"{"alg":"HS256","typ":"JWT"}"#);
    let payload = B64.encode(serde_json::to_vec(&claims).unwrap());
    let input = format!("{header}.{payload}");
    let mut mac = Hmac::<Sha256>::new_from_slice(SECRET.as_bytes()).unwrap();
    mac.update(input.as_bytes());
    format!("{input}.{}", B64.encode(mac.finalize().into_bytes()))
}

struct Silent;
impl Transcriber for Silent {
    fn transcribe(&self, _: &[i16], _: Option<&str>) -> anyhow::Result<Transcript> {
        unreachable!()
    }
    fn model(&self) -> String {
        "none".into()
    }
}

struct NoSessions;
impl Launcher for NoSessions {
    fn launch(&self, _: Launch) -> Running {
        unreachable!()
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn a_spoken_line_is_heard_in_the_room_from_the_labelled_participant() {
    let (Ok(url), Ok(bin), Ok(model)) = (
        std::env::var("LISTENER_REAL_LIVEKIT"),
        std::env::var("LISTENER_TEST_PIPER_BIN"),
        std::env::var("LISTENER_TEST_PIPER_MODEL"),
    ) else {
        eprintln!(
            "skipped: LISTENER_REAL_LIVEKIT and the LISTENER_TEST_PIPER_* variables are not set"
        );
        return;
    };
    let mut listener = LiveKitRoom::connect(&url, &token("alice", "Alice", false))
        .await
        .expect("a listener joins the call");
    let config = Arc::new(
        Config::from_map(&std::collections::HashMap::from([(
            "LISTENER_SECRET".to_owned(),
            LISTENER_SECRET.to_owned(),
        )]))
        .unwrap(),
    );
    let piper = Piper::new(bin.into(), model.into()).expect("the voice loads");
    let control = Control::new(
        config,
        Arc::new(Pool::new(Arc::new(Silent), 1)),
        Arc::new(NoSessions),
    )
    .with_speaker(Speaker {
        synthesizer: Arc::new(piper),
        stage: Arc::new(LiveKitStage),
    });
    let body = serde_json::json!({
        "livekit_url": url,
        "token": token("tts-bob", "Bob (TTS)", true),
        "text": LINE,
    });
    let request = Request::post("/v1/speak")
        .header("authorization", format!("Bearer {LISTENER_SECRET}"))
        .header("content-type", "application/json")
        .body(Body::from(body.to_string()))
        .unwrap();
    let speaking =
        tokio::spawn(async move { control.router().oneshot(request).await.unwrap().status() });

    let mut heard: Vec<i16> = Vec::new();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(40);
    while tokio::time::Instant::now() < deadline {
        let Ok(event) = tokio::time::timeout(Duration::from_secs(2), listener.next_event()).await
        else {
            if speaking.is_finished() {
                break;
            }
            continue;
        };
        match event {
            Some(Seen::Published {
                track, microphone, ..
            }) => {
                assert_eq!(
                    track.identity, "tts-bob",
                    "only the labelled participant publishes"
                );
                assert!(
                    microphone,
                    "the speech is a microphone track, so it plays like a voice"
                );
                listener.subscribe(&track, true);
            }
            Some(Seen::Audio { identity, samples }) => {
                assert_eq!(identity, "tts-bob");
                heard.extend(samples);
            }
            Some(Seen::Left { identity }) => {
                assert_eq!(identity, "tts-bob");
                break;
            }
            Some(_) => {}
            None => break,
        }
    }
    assert_eq!(speaking.await.unwrap(), axum::http::StatusCode::NO_CONTENT);
    listener.leave().await;

    let loud = heard.iter().filter(|s| s.unsigned_abs() > 800).count();
    let seconds = loud as f64 / 16_000.0;
    eprintln!(
        "heard {} samples, {seconds:.2} s above the noise floor",
        heard.len()
    );
    assert!(
        seconds > 0.8,
        "a line of speech is audible, got {seconds:.2} s"
    );
}
