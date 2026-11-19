// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Voice message transcripts: made in the background for a Space that turned
//! them on, searchable, announced live, hidden when the setting goes off, and
//! gone with the message. The speech engine is a fake.

use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};

use serde_json::{Value, json};
use slimm_server::hub::{Event, Hub, MessageEvent};
use slimm_server::ids::MessageId;
use slimm_server::voice_transcripts::{
    EngineFuture, Failure, Heard, MAX_ATTEMPTS, SpeechEngine, VoiceTranscriber,
};
use tower::ServiceExt;
use uuid::Uuid;

use crate::attachments::fixtures::*;
use crate::attachments::text_search::{World, world};

pub(super) struct Fake {
    answer: Mutex<Result<Heard, Failure>>,
    pub(super) calls: AtomicUsize,
}

impl Fake {
    pub(super) fn saying(text: &str) -> Self {
        Self {
            answer: Mutex::new(Ok(Heard {
                text: text.into(),
                language: Some("en".into()),
            })),
            calls: AtomicUsize::new(0),
        }
    }

    pub(super) fn failing(failure: Failure) -> Self {
        Self {
            answer: Mutex::new(Err(failure)),
            calls: AtomicUsize::new(0),
        }
    }
}

impl SpeechEngine for Fake {
    fn transcribe(&self, _: Vec<u8>) -> EngineFuture<'_> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        let answer = self.answer.lock().unwrap().clone();
        Box::pin(async move { answer })
    }
}

fn waveform() -> String {
    "10".repeat(64)
}

/// Sends a voice message and returns its message id and attachment id.
pub(super) async fn send_voice(world: &World, tail: u8) -> (String, String) {
    let uploaded = {
        let mut bytes = b"OggS".to_vec();
        bytes.extend([0, tail, 9, 9]);
        let response = world
            .app
            .clone()
            .oneshot(request_bytes(
                "POST",
                &format!(
                    "/attachments?filename=voice.ogg&voice=true&duration_ms=3000&waveform={}",
                    waveform()
                ),
                &world.token,
                bytes,
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), 201);
        json_body(response).await
    };
    let id = Uuid::now_v7().to_string();
    let sent = world
        .app
        .clone()
        .oneshot(request_json(
            "POST",
            &format!("/channels/{}/messages", world.channel),
            &world.token,
            json!({ "id": id, "content": "", "attachment_ids": [uploaded["id"]] }),
        ))
        .await
        .unwrap();
    assert_eq!(sent.status(), 200);
    (id, uploaded["id"].as_str().unwrap().to_owned())
}

pub(super) async fn transcript_of(world: &World, message_id: &str) -> Value {
    let response = world
        .app
        .clone()
        .oneshot(request_plain(
            "GET",
            &format!("/channels/{}/messages", world.channel),
            &world.token,
        ))
        .await
        .unwrap();
    let list = json_body(response).await;
    let messages = list
        .as_array()
        .cloned()
        .unwrap_or_else(|| list["messages"].as_array().unwrap().clone());
    let message = messages.iter().find(|m| m["id"] == message_id).unwrap();
    message["attachments"][0]
        .get("transcript")
        .cloned()
        .unwrap_or(Value::Null)
}

async fn pass(world: &World, engine: &Fake, hub: &Hub) -> usize {
    VoiceTranscriber::with_backoff(std::time::Duration::from_millis(1))
        .run_pass(&world.store, &world.media, hub, engine)
        .await
}

#[tokio::test]
async fn nothing_is_transcribed_until_the_space_turns_it_on() {
    let world = world().await;
    let (message, _) = send_voice(&world, 1).await;
    let engine = Fake::saying("hello there");
    assert_eq!(pass(&world, &engine, &Hub::new()).await, 0);
    assert_eq!(engine.calls.load(Ordering::SeqCst), 0);
    assert_eq!(transcript_of(&world, &message).await, Value::Null);
}

#[tokio::test]
async fn a_voice_message_is_transcribed_announced_and_found_by_search() {
    let world = world().await;
    world
        .store
        .set_transcribe_voice_messages(true)
        .await
        .unwrap();
    let (message, attachment) = send_voice(&world, 2).await;
    let hub = Hub::new();
    let mut events = hub.subscribe_ephemeral();
    let engine = Fake::saying("meet me at the lighthouse");
    assert_eq!(pass(&world, &engine, &hub).await, 1);

    let transcript = transcript_of(&world, &message).await;
    assert_eq!(transcript["status"], "ready");
    assert_eq!(transcript["text"], "meet me at the lighthouse");
    assert_eq!(
        world.search("lighthouse").await.len(),
        1,
        "search finds the words"
    );

    let mut seen = Vec::new();
    while let Ok(Event::Message(MessageEvent::VoiceTranscript {
        attachment_id,
        status,
        ..
    })) = events.try_recv()
    {
        assert_eq!(attachment_id, attachment);
        seen.push(status);
    }
    assert_eq!(seen, ["pending", "ready"]);

    assert_eq!(pass(&world, &engine, &hub).await, 0, "done once");
    assert_eq!(engine.calls.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn turning_the_setting_off_hides_what_was_made() {
    let world = world().await;
    world
        .store
        .set_transcribe_voice_messages(true)
        .await
        .unwrap();
    let (message, _) = send_voice(&world, 3).await;
    pass(&world, &Fake::saying("secret plans"), &Hub::new()).await;
    assert_eq!(transcript_of(&world, &message).await["status"], "ready");
    assert_eq!(world.search("plans").await.len(), 1);
    let ids = [MessageId(Uuid::parse_str(&message).unwrap())];
    let matched = || world.store.attachments_matching_text(&ids, "plans");
    assert_eq!(matched().await.unwrap().len(), 1);

    world
        .store
        .set_transcribe_voice_messages(false)
        .await
        .unwrap();
    assert_eq!(transcript_of(&world, &message).await, Value::Null);
    assert!(world.search("plans").await.is_empty(), "search arm");
    assert!(matched().await.unwrap().is_empty(), "found-in label");

    world
        .store
        .set_transcribe_voice_messages(true)
        .await
        .unwrap();
    assert_eq!(world.search("plans").await.len(), 1, "back when turned on");
}

async fn shown_on_version(world: &World) -> Value {
    let response = world
        .app
        .clone()
        .oneshot(request_plain("GET", "/version", &world.token))
        .await
        .unwrap();
    json_body(response).await["transcribe_voice_messages"].clone()
}

#[tokio::test]
async fn version_says_whether_transcripts_show_so_clients_hide_theirs() {
    let world = world().await;
    assert_eq!(shown_on_version(&world).await, false);

    world
        .store
        .set_transcribe_voice_messages(true)
        .await
        .unwrap();
    assert_eq!(shown_on_version(&world).await, true);

    world
        .store
        .set_transcribe_voice_messages(false)
        .await
        .unwrap();
    assert_eq!(shown_on_version(&world).await, false);
}

#[tokio::test]
async fn a_failing_engine_leaves_it_pending_and_a_refusal_fails_it_for_good() {
    let world = world().await;
    world
        .store
        .set_transcribe_voice_messages(true)
        .await
        .unwrap();
    let (message, _) = send_voice(&world, 4).await;
    assert_eq!(
        pass(&world, &Fake::failing(Failure::Transient), &Hub::new()).await,
        0
    );
    assert_eq!(transcript_of(&world, &message).await["status"], "pending");

    tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    let refusing = Fake::failing(Failure::Permanent);
    assert_eq!(pass(&world, &refusing, &Hub::new()).await, 1);
    assert_eq!(transcript_of(&world, &message).await["status"], "failed");
    the_retry_time_comes(&world).await;
    let healthy = Fake::saying("never asked");
    assert_eq!(pass(&world, &healthy, &Hub::new()).await, 0);
    assert_eq!(healthy.calls.load(Ordering::SeqCst), 0, "not tried again");
}

/// What a day does to every transcript the worker gave up on.
async fn the_retry_time_comes(world: &World) {
    sqlx::query("UPDATE attachment_transcripts SET retry_at = 0 WHERE retry_at IS NOT NULL")
        .execute(&world.pool)
        .await
        .unwrap();
}

#[tokio::test]
async fn a_pass_tries_each_clip_once_even_when_its_backoff_is_already_over() {
    let world = world().await;
    world
        .store
        .set_transcribe_voice_messages(true)
        .await
        .unwrap();
    let (message, _) = send_voice(&world, 7).await;
    let transcriber = VoiceTranscriber::with_backoff(std::time::Duration::ZERO);
    let broken = Fake::failing(Failure::Transient);
    transcriber
        .run_pass(&world.store, &world.media, &Hub::new(), &broken)
        .await;
    assert_eq!(broken.calls.load(Ordering::SeqCst), 1, "one try per pass");
    assert_eq!(transcript_of(&world, &message).await["status"], "pending");
}

#[tokio::test]
async fn a_clip_the_listener_keeps_failing_ends_failed_then_is_tried_again() {
    let world = world().await;
    world
        .store
        .set_transcribe_voice_messages(true)
        .await
        .unwrap();
    let (message, _) = send_voice(&world, 7).await;
    let transcriber = VoiceTranscriber::with_backoff(std::time::Duration::from_millis(1));
    let broken = Fake::failing(Failure::Transient);
    for attempt in 1..MAX_ATTEMPTS {
        transcriber
            .run_pass(&world.store, &world.media, &Hub::new(), &broken)
            .await;
        assert_eq!(
            transcript_of(&world, &message).await["status"],
            "pending",
            "still trying after {attempt}"
        );
        // The backoff doubles from 1 ms, so wait it out before the next pass.
        tokio::time::sleep(std::time::Duration::from_millis(2 << attempt)).await;
    }
    transcriber
        .run_pass(&world.store, &world.media, &Hub::new(), &broken)
        .await;
    assert_eq!(transcript_of(&world, &message).await["status"], "failed");
    assert_eq!(broken.calls.load(Ordering::SeqCst), MAX_ATTEMPTS as usize);

    let fixed = Fake::saying("worth the wait");
    transcriber
        .run_pass(&world.store, &world.media, &Hub::new(), &fixed)
        .await;
    assert_eq!(fixed.calls.load(Ordering::SeqCst), 0, "not before its time");
    the_retry_time_comes(&world).await;
    transcriber
        .run_pass(&world.store, &world.media, &Hub::new(), &broken)
        .await;
    assert_eq!(
        broken.calls.load(Ordering::SeqCst),
        MAX_ATTEMPTS as usize + 1,
        "a retry is one try"
    );
    assert_eq!(transcript_of(&world, &message).await["status"], "failed");
    transcriber
        .run_pass(&world.store, &world.media, &Hub::new(), &fixed)
        .await;
    assert_eq!(fixed.calls.load(Ordering::SeqCst), 0, "then waits again");
    the_retry_time_comes(&world).await;
    assert_eq!(
        transcriber
            .run_pass(&world.store, &world.media, &Hub::new(), &fixed)
            .await,
        1
    );
    assert_eq!(
        transcript_of(&world, &message).await["text"],
        "worth the wait"
    );
}

#[tokio::test]
async fn a_listener_without_the_route_stops_the_pass_at_the_first_clip() {
    let world = world().await;
    world
        .store
        .set_transcribe_voice_messages(true)
        .await
        .unwrap();
    for tail in 8..11 {
        send_voice(&world, tail).await;
    }
    let old = Fake::failing(Failure::Unavailable);
    let (transcriber, hub) = (
        VoiceTranscriber::with_backoff(std::time::Duration::from_secs(60)),
        Hub::new(),
    );
    let run = || transcriber.run_pass(&world.store, &world.media, &hub, &old);
    assert_eq!(run().await, 0);
    assert_eq!(old.calls.load(Ordering::SeqCst), 1, "the others wait");
    assert_eq!(run().await, 0);
    assert_eq!(
        old.calls.load(Ordering::SeqCst),
        1,
        "the next pass waits for the listener too"
    );
}

#[tokio::test]
async fn a_listener_outage_costs_no_clip_an_attempt_and_its_clips_follow_when_it_returns() {
    let world = world().await;
    world
        .store
        .set_transcribe_voice_messages(true)
        .await
        .unwrap();
    let (first, _) = send_voice(&world, 12).await;
    let (second, _) = send_voice(&world, 13).await;
    let step = std::time::Duration::from_micros(200);
    let transcriber = VoiceTranscriber::with_backoff(step);
    let down = Fake::failing(Failure::Unavailable);
    let passes = MAX_ATTEMPTS + 2;
    for attempt in 0..passes {
        transcriber
            .run_pass(&world.store, &world.media, &Hub::new(), &down)
            .await;
        // The listener's backoff doubles from one step, so wait it out before the next pass.
        tokio::time::sleep(step * (2 << attempt)).await;
    }
    assert_eq!(down.calls.load(Ordering::SeqCst), passes as usize);
    let statuses = sqlx::query_scalar::<_, String>("SELECT status FROM attachment_transcripts")
        .fetch_all(&world.pool)
        .await
        .unwrap();
    assert!(!statuses.contains(&"failed".to_owned()), "{statuses:?}");

    let back = Fake::saying("the listener is back");
    transcriber
        .run_pass(&world.store, &world.media, &Hub::new(), &back)
        .await;
    assert_eq!(back.calls.load(Ordering::SeqCst), 2, "both clips follow");
    for message in [first, second] {
        assert_eq!(transcript_of(&world, &message).await["status"], "ready");
    }
}

#[tokio::test]
async fn a_clip_sent_while_the_listener_is_down_is_not_shown_transcribing() {
    let world = world().await;
    world
        .store
        .set_transcribe_voice_messages(true)
        .await
        .unwrap();
    let (first, _) = send_voice(&world, 14).await;
    let transcriber = VoiceTranscriber::with_backoff(std::time::Duration::from_millis(1));
    let down = Fake::failing(Failure::Unavailable);
    transcriber
        .run_pass(&world.store, &world.media, &Hub::new(), &down)
        .await;
    assert_eq!(
        transcript_of(&world, &first).await,
        Value::Null,
        "the clip that found the listener down"
    );
    let (later, _) = send_voice(&world, 15).await;
    tokio::time::sleep(std::time::Duration::from_millis(5)).await;
    transcriber
        .run_pass(&world.store, &world.media, &Hub::new(), &down)
        .await;
    assert_eq!(down.calls.load(Ordering::SeqCst), 2, "the new clip probed");
    assert_eq!(transcript_of(&world, &later).await, Value::Null);
}

#[tokio::test]
async fn an_encrypted_message_is_never_offered_to_the_engine() {
    let world = world().await;
    world
        .store
        .set_transcribe_voice_messages(true)
        .await
        .unwrap();
    send_voice(&world, 5).await;
    sqlx::query("UPDATE messages SET is_encrypted = 1")
        .execute(&world.pool)
        .await
        .unwrap();
    let engine = Fake::saying("should not be heard");
    assert_eq!(pass(&world, &engine, &Hub::new()).await, 0);
    assert_eq!(engine.calls.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn deleting_the_message_deletes_the_transcript_and_its_index_row() {
    let world = world().await;
    world
        .store
        .set_transcribe_voice_messages(true)
        .await
        .unwrap();
    let (message, _) = send_voice(&world, 6).await;
    pass(&world, &Fake::saying("gone soon"), &Hub::new()).await;
    let count = |sql: &'static str| {
        let pool = world.pool.clone();
        async move {
            sqlx::query_scalar::<_, i64>(sql)
                .fetch_one(&pool)
                .await
                .unwrap()
        }
    };
    assert_eq!(
        count("SELECT COUNT(*) FROM attachment_transcripts").await,
        1
    );
    let deleted = world
        .app
        .clone()
        .oneshot(request_plain(
            "DELETE",
            &format!("/channels/{}/messages/{message}", world.channel),
            &world.token,
        ))
        .await
        .unwrap();
    assert_eq!(deleted.status(), 204);
    assert_eq!(
        count("SELECT COUNT(*) FROM attachment_transcripts").await,
        0
    );
    assert_eq!(count("SELECT COUNT(*) FROM attachment_text_fts").await, 0);
}
