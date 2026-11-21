// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The listener against a real `livekit-server --dev`, with the tiny English
//! model: two people publish a generated voice and only the included one is
//! heard, a speaker who publishes before or after the listener joined is
//! transcribed, and a speaker's mute and unmute reach the listener.
//!
//! Opt in with `LISTENER_REAL_LIVEKIT=ws://127.0.0.1:7880` and
//! `LISTENER_TEST_MODEL` (a ggml model file), plus `LISTENER_TEST_WAV_SCRIPT`
//! (`scripts/lib/make_fake_voice.py`) for the first test and
//! `LISTENER_TEST_SPEECH_WAV` (espeak-ng speech) for the two transcribed
//! ones. Without them each test passes at once.
#![cfg(all(feature = "livekit-room", feature = "whisper"))]

use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD as B64;
use hmac::{Hmac, Mac};
use livekit::options::TrackPublishOptions;
use livekit::prelude::*;
use livekit::webrtc::audio_frame::AudioFrame;
use livekit::webrtc::audio_source::native::NativeAudioSource;
use livekit::webrtc::audio_source::{AudioSourceOptions, RtcAudioSource};
use sha2::Sha256;
use slimm_listener::protocol::Report;
use slimm_listener::room::{LiveKitRoom, RoomEvent as Seen, RoomSource, TrackRef};
use slimm_listener::session::{Params, SessionCommand, run};
use slimm_listener::stt::{Pool, WhisperTranscriber};
use tokio::sync::mpsc::unbounded_channel;

const KEY: &str = "devkey";
const SECRET: &str = "secret";
const ROOM: &str = "listener-real-test";
const RATE: usize = 48_000;

/// A development-server token for `identity`.
fn token(identity: &str, can_publish: bool, hidden: bool) -> String {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs();
    let claims = serde_json::json!({
        "iss": KEY, "sub": identity, "nbf": now, "exp": now + 600,
        "video": {"room": ROOM, "roomJoin": true, "canSubscribe": true,
            "canPublish": can_publish, "canPublishData": false, "hidden": hidden},
    });
    let header = B64.encode(r#"{"alg":"HS256","typ":"JWT"}"#);
    let payload = B64.encode(serde_json::to_vec(&claims).unwrap());
    let input = format!("{header}.{payload}");
    let mut mac = Hmac::<Sha256>::new_from_slice(SECRET.as_bytes()).unwrap();
    mac.update(input.as_bytes());
    format!("{input}.{}", B64.encode(mac.finalize().into_bytes()))
}

fn wav_samples(script: &str) -> Vec<i16> {
    let path = std::env::temp_dir().join("listener-real-voice.wav");
    let status = std::process::Command::new("python3")
        .arg("-I")
        .arg(script)
        .arg(&path)
        .status()
        .expect("python3 runs");
    assert!(status.success());
    let bytes = std::fs::read(path).unwrap();
    bytes[44..]
        .chunks_exact(2)
        .map(|b| i16::from_le_bytes([b[0], b[1]]))
        .collect()
}

/// Joins as `identity` and keeps speaking the generated voice until dropped.
async fn speaker(
    url: &str,
    identity: &str,
    voice: Vec<i16>,
) -> (Room, tokio::task::JoinHandle<()>) {
    let (room, _events) = Room::connect(url, &token(identity, true, false), RoomOptions::default())
        .await
        .expect("a speaker joins");
    let source = NativeAudioSource::new(AudioSourceOptions::default(), RATE as u32, 1, 100);
    let track = LocalAudioTrack::create_audio_track("mic", RtcAudioSource::Native(source.clone()));
    let options = TrackPublishOptions {
        source: TrackSource::Microphone,
        ..TrackPublishOptions::default()
    };
    room.local_participant()
        .publish_track(LocalTrack::Audio(track), options)
        .await
        .expect("the microphone publishes");
    let task = tokio::spawn(async move {
        let _keep = _events;
        loop {
            for chunk in voice.chunks(RATE / 100) {
                let frame = AudioFrame {
                    data: chunk.into(),
                    sample_rate: RATE as u32,
                    num_channels: 1,
                    samples_per_channel: chunk.len() as u32,
                };
                if source.capture_frame(&frame).await.is_err() {
                    return;
                }
            }
        }
    });
    (room, task)
}

/// Passes everything through and notes whose audio arrived.
struct Spy<R> {
    inner: R,
    heard: Arc<Mutex<HashSet<String>>>,
}

impl<R: RoomSource> RoomSource for Spy<R> {
    async fn next_event(&mut self) -> Option<Seen> {
        let event = self.inner.next_event().await;
        if let Some(Seen::Audio { identity, .. }) = &event {
            self.heard.lock().unwrap().insert(identity.clone());
        }
        event
    }

    fn subscribe(&mut self, track: &TrackRef, on: bool) {
        self.inner.subscribe(track, on);
    }

    async fn leave(&mut self) {
        self.inner.leave().await;
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn audio_frames_come_only_from_included_identities() {
    let (Ok(url), Ok(model), Ok(script)) = (
        std::env::var("LISTENER_REAL_LIVEKIT"),
        std::env::var("LISTENER_TEST_MODEL"),
        std::env::var("LISTENER_TEST_WAV_SCRIPT"),
    ) else {
        eprintln!(
            "skipped: LISTENER_REAL_LIVEKIT, LISTENER_TEST_MODEL and LISTENER_TEST_WAV_SCRIPT are not all set"
        );
        return;
    };
    let voice = wav_samples(&script);
    let (_alice, alice_task) = speaker(&url, "alice", voice.clone()).await;
    let (_bob, bob_task) = speaker(&url, "bob", voice).await;

    let room = LiveKitRoom::connect(&url, &token("listener-real", false, true))
        .await
        .expect("the listener joins hidden");
    let heard = Arc::new(Mutex::new(HashSet::new()));
    let spy = Spy {
        inner: room,
        heard: Arc::clone(&heard),
    };
    let transcriber = WhisperTranscriber::load(&PathBuf::from(model)).expect("the model loads");
    let pool = Arc::new(Pool::new(Arc::new(transcriber), 2));
    let (commands, feed) = unbounded_channel();
    let (reports, mut seen) = unbounded_channel::<Report>();
    let params = Params {
        id: "real".into(),
        include: ["alice".to_owned()].into(),
        language: Some("en".into()),
    };
    let session = tokio::spawn(run(params, spy, feed, pool, reports));

    tokio::time::sleep(Duration::from_secs(12)).await;
    commands.send(SessionCommand::Stop).unwrap();
    session.await.unwrap();
    alice_task.abort();
    bob_task.abort();

    let heard = heard.lock().unwrap().clone();
    assert!(
        heard.contains("alice"),
        "an included speaker is heard: {heard:?}"
    );
    assert!(
        !heard.contains("bob"),
        "an excluded speaker never is: {heard:?}"
    );
    while let Ok(report) = seen.try_recv() {
        if let Report::Segment { identity, .. } = report {
            assert_eq!(identity, "alice");
        }
    }
}

/// A mono 16-bit WAV with a 44-byte header (espeak-ng writes one), resampled to [`RATE`].
fn speech_file(path: &str) -> Vec<i16> {
    let bytes = std::fs::read(path).unwrap();
    let rate = u32::from_le_bytes(bytes[24..28].try_into().unwrap()) as usize;
    let source: Vec<i16> = bytes[44..]
        .chunks_exact(2)
        .map(|b| i16::from_le_bytes([b[0], b[1]]))
        .collect();
    let length = source.len() * RATE / rate;
    (0..length)
        .map(|n| source[(n * rate / RATE).min(source.len() - 1)])
        .collect()
}

/// When the speaker's microphone is published, relative to the listener joining.
#[derive(Clone, Copy)]
enum Publishes {
    BeforeTheListener,
    AfterTheListener,
}

/// A call's first speaker usually publishes after the listener joined, so this path gets its own test.
#[tokio::test(flavor = "multi_thread")]
async fn a_speaker_who_publishes_after_the_listener_joined_is_transcribed() {
    speech_comes_back_as_words("carol", Publishes::AfterTheListener).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_speaker_who_published_before_the_listener_joined_is_transcribed() {
    speech_comes_back_as_words("dave", Publishes::BeforeTheListener).await;
}

/// `who` speaks the espeak-ng sentence and the listener must send it back as words, from `who` alone.
async fn speech_comes_back_as_words(who: &str, publishes: Publishes) {
    let (Ok(url), Ok(model), Ok(speech)) = (
        std::env::var("LISTENER_REAL_LIVEKIT"),
        std::env::var("LISTENER_TEST_MODEL"),
        std::env::var("LISTENER_TEST_SPEECH_WAV"),
    ) else {
        eprintln!(
            "skipped: LISTENER_REAL_LIVEKIT, LISTENER_TEST_MODEL and LISTENER_TEST_SPEECH_WAV are not all set"
        );
        return;
    };
    let early = match publishes {
        Publishes::BeforeTheListener => Some(speaker(&url, who, speech_file(&speech)).await),
        Publishes::AfterTheListener => None,
    };
    let room = LiveKitRoom::connect(&url, &token(&format!("listener-{who}"), false, true))
        .await
        .expect("the listener joins hidden");
    let heard = Arc::new(Mutex::new(HashSet::new()));
    let spy = Spy {
        inner: room,
        heard: Arc::clone(&heard),
    };
    let transcriber = WhisperTranscriber::load(&PathBuf::from(model)).expect("the model loads");
    let pool = Arc::new(Pool::new(Arc::new(transcriber), 2));
    let (commands, feed) = unbounded_channel();
    let (reports, mut seen) = unbounded_channel::<Report>();
    let params = Params {
        id: who.into(),
        include: [who.to_owned()].into(),
        language: Some("en".into()),
    };
    let session = tokio::spawn(run(params, spy, feed, pool, reports));

    let (_speaker, speaking) = match early {
        Some(early) => early,
        None => {
            tokio::time::sleep(Duration::from_secs(2)).await;
            speaker(&url, who, speech_file(&speech)).await
        }
    };
    tokio::time::sleep(Duration::from_secs(10)).await;
    commands.send(SessionCommand::Stop).unwrap();
    session.await.unwrap();
    speaking.abort();

    assert!(heard.lock().unwrap().contains(who), "{who} is heard");
    let mut text = String::new();
    while let Ok(report) = seen.try_recv() {
        if let Report::Segment {
            identity,
            text: words,
            ..
        } = report
        {
            assert_eq!(identity, who);
            text.push_str(&words);
        }
    }
    assert!(
        text.to_lowercase().contains("listener"),
        "{who}'s speech comes back as words: {text:?}"
    );
}

/// The next event about `who`'s tracks that is not audio, within ten seconds.
async fn next_about(room: &mut LiveKitRoom, who: &str) -> Seen {
    let wait = async {
        loop {
            match room.next_event().await.expect("the room stays open") {
                Seen::Published { track, .. } | Seen::Muted { track, .. }
                    if track.identity != who => {}
                event @ (Seen::Published { .. } | Seen::Muted { .. }) => return event,
                _ => {}
            }
        }
    };
    tokio::time::timeout(Duration::from_secs(10), wait)
        .await
        .expect("an event in time")
}

/// A muted microphone stays published and sends silence, so the listener is told, or a muted speaker reads as a silent one.
#[tokio::test(flavor = "multi_thread")]
async fn a_speakers_mute_and_unmute_reach_the_listener() {
    let Ok(url) = std::env::var("LISTENER_REAL_LIVEKIT") else {
        eprintln!("skipped: LISTENER_REAL_LIVEKIT is not set");
        return;
    };
    let (dave, dave_task) = speaker(&url, "dave", vec![0; RATE / 100]).await;
    let mic = dave
        .local_participant()
        .track_publications()
        .into_values()
        .next()
        .expect("dave's microphone");
    mic.mute();
    tokio::time::sleep(Duration::from_millis(500)).await;
    let mut room = LiveKitRoom::connect(&url, &token("listener-mute", false, true))
        .await
        .expect("the listener joins hidden");

    let joined = next_about(&mut room, "dave").await;
    assert!(
        matches!(
            joined,
            Seen::Published {
                microphone: true,
                muted: true,
                ..
            }
        ),
        "a microphone muted before the listener joined says so: {joined:?}"
    );
    mic.unmute();
    let unmuted = next_about(&mut room, "dave").await;
    assert!(
        matches!(unmuted, Seen::Muted { muted: false, .. }),
        "{unmuted:?}"
    );
    mic.mute();
    let muted = next_about(&mut room, "dave").await;
    assert!(
        matches!(muted, Seen::Muted { muted: true, .. }),
        "{muted:?}"
    );

    room.leave().await;
    dave_task.abort();
}
