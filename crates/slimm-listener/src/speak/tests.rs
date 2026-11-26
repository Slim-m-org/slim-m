// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
use std::sync::Mutex;

use axum::body::Body;
use axum::http::Request;
use tower::ServiceExt;

use super::*;
use crate::config::Config;
use crate::control::{Launch, Launcher, Running};
use crate::stt::{Pool, Transcriber, Transcript};

const SECRET: &str = "0123456789abcdef0123456789abcdef";

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
        unreachable!("speech starts no session")
    }
}

/// Says each line is `len` samples of 16 kHz.
struct Fixed(usize);
impl Synthesizer for Fixed {
    fn synthesize<'a>(&'a self, _: &'a str) -> Boxed<'a, Speech> {
        Box::pin(async move {
            Ok(Speech {
                samples: vec![5; self.0],
                sample_rate: 16_000,
            })
        })
    }
}

struct Failing;
impl Synthesizer for Failing {
    fn synthesize<'a>(&'a self, _: &'a str) -> Boxed<'a, Speech> {
        Box::pin(async { anyhow::bail!("no voice") })
    }
}

/// Records what it was asked to play.
#[derive(Default)]
struct Recorder(Mutex<Vec<(String, String, usize)>>);
impl Stage for Arc<Recorder> {
    fn perform<'a>(&'a self, url: &'a str, token: &'a str, speech: &'a Speech) -> Boxed<'a, ()> {
        Box::pin(async move {
            self.0
                .lock()
                .unwrap()
                .push((url.into(), token.into(), speech.samples.len()));
            Ok(())
        })
    }
}

struct Broken;
impl Stage for Broken {
    fn perform<'a>(&'a self, _: &'a str, _: &'a str, _: &'a Speech) -> Boxed<'a, ()> {
        Box::pin(async { anyhow::bail!("room refused") })
    }
}

fn config() -> Arc<Config> {
    Arc::new(
        Config::from_map(&std::collections::HashMap::from([(
            "LISTENER_SECRET".to_owned(),
            SECRET.to_owned(),
        )]))
        .unwrap(),
    )
}

fn control(speaker: Option<Speaker>) -> Control {
    let pool = Arc::new(Pool::new(Arc::new(Silent), 1));
    let control = Control::new(config(), pool, Arc::new(NoSessions));
    match speaker {
        Some(speaker) => control.with_speaker(speaker),
        None => control,
    }
}

fn speaker(synth: impl Synthesizer, stage: impl Stage) -> Speaker {
    Speaker {
        synthesizer: Arc::new(synth),
        stage: Arc::new(stage),
    }
}

async fn post(control: Control, secret: &str, body: serde_json::Value) -> StatusCode {
    let request = Request::post("/v1/speak")
        .header("authorization", format!("Bearer {secret}"))
        .header("content-type", "application/json")
        .body(Body::from(body.to_string()))
        .unwrap();
    control.router().oneshot(request).await.unwrap().status()
}

fn body(text: &str) -> serde_json::Value {
    serde_json::json!({"livekit_url": "ws://lk", "token": "jwt", "text": text})
}

#[tokio::test]
async fn a_line_is_synthesised_and_played_into_the_room_it_names() {
    let stage = Arc::new(Recorder::default());
    let control = control(Some(speaker(Fixed(1600), Arc::clone(&stage))));
    assert_eq!(
        post(control, SECRET, body("hello  there\nfriend")).await,
        StatusCode::NO_CONTENT
    );
    assert_eq!(
        *stage.0.lock().unwrap(),
        vec![("ws://lk".into(), "jwt".into(), 1600)]
    );
}

#[tokio::test]
async fn a_caller_without_the_secret_is_refused_and_nothing_is_played() {
    let stage = Arc::new(Recorder::default());
    let control = control(Some(speaker(Fixed(1600), Arc::clone(&stage))));
    assert_eq!(
        post(control, "wrong", body("hello")).await,
        StatusCode::UNAUTHORIZED
    );
    assert!(stage.0.lock().unwrap().is_empty());
}

#[tokio::test]
async fn a_listener_without_a_voice_says_not_implemented() {
    assert_eq!(
        post(control(None), SECRET, body("hello")).await,
        StatusCode::NOT_IMPLEMENTED
    );
}

#[tokio::test]
async fn empty_and_overlong_lines_are_refused_before_synthesis() {
    let long = "a".repeat(MAX_TEXT_CHARS + 1);
    for text in ["", "  \n ", long.as_str()] {
        let control = control(Some(speaker(Failing, Broken)));
        assert_eq!(
            post(control, SECRET, body(text)).await,
            StatusCode::UNPROCESSABLE_ENTITY
        );
    }
}

#[tokio::test]
async fn speech_longer_than_the_cap_is_refused_not_cut() {
    let stage = Arc::new(Recorder::default());
    let samples = 16_000 * (MAX_SPEECH.as_secs() as usize + 1);
    let control = control(Some(speaker(Fixed(samples), Arc::clone(&stage))));
    assert_eq!(
        post(control, SECRET, body("hello")).await,
        StatusCode::UNPROCESSABLE_ENTITY
    );
    assert!(stage.0.lock().unwrap().is_empty());
}

#[tokio::test]
async fn a_failed_synthesis_and_a_refused_room_are_told_apart() {
    let a = control(Some(speaker(Failing, Broken)));
    assert_eq!(
        post(a, SECRET, body("hello")).await,
        StatusCode::INTERNAL_SERVER_ERROR
    );
    let b = control(Some(speaker(Fixed(1600), Broken)));
    assert_eq!(
        post(b, SECRET, body("hello")).await,
        StatusCode::BAD_GATEWAY
    );
}

#[tokio::test]
async fn the_status_route_says_whether_a_voice_is_set_up() {
    let get = |control: Control, secret: &str| {
        let request = Request::get("/v1/speak")
            .header("authorization", format!("Bearer {secret}"))
            .body(Body::empty())
            .unwrap();
        async move { control.router().oneshot(request).await.unwrap().status() }
    };
    let on = control(Some(speaker(Fixed(1), Broken)));
    assert_eq!(get(on, SECRET).await, StatusCode::NO_CONTENT);
    assert_eq!(
        get(control(None), SECRET).await,
        StatusCode::NOT_IMPLEMENTED
    );
    let on = control(Some(speaker(Fixed(1), Broken)));
    assert_eq!(get(on, "wrong").await, StatusCode::UNAUTHORIZED);
}
