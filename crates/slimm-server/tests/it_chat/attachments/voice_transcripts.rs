// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Voice message transcripts: made in the background for a Space that turned
//! them on, searchable, announced live, hidden when the setting goes off, and
//! gone with the message. The speech engine is a fake.

use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};

use serde_json::{Value, json};
use slimm_server::hub::{Event, Hub, MessageEvent};
use slimm_server::voice_transcripts::{
    EngineFuture, Failure, Heard, SpeechEngine, VoiceTranscriber,
};
use tower::ServiceExt;
use uuid::Uuid;

use crate::attachments::fixtures::*;
use crate::attachments::text_search::{World, world};

struct Fake {
    answer: Mutex<Result<Heard, Failure>>,
    calls: AtomicUsize,
}

impl Fake {
    fn saying(text: &str) -> Self {
        Self {
            answer: Mutex::new(Ok(Heard {
                text: text.into(),
                language: Some("en".into()),
            })),
            calls: AtomicUsize::new(0),
        }
    }

    fn failing(failure: Failure) -> Self {
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
async fn send_voice(world: &World, tail: u8) -> (String, String) {
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

async fn transcript_of(world: &World, message_id: &str) -> Value {
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
    world
        .store
        .set_transcribe_voice_messages(false)
        .await
        .unwrap();
    assert_eq!(transcript_of(&world, &message).await, Value::Null);
}

#[tokio::test]
async fn an_unreachable_engine_leaves_it_pending_and_a_refusal_fails_it() {
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
    assert_eq!(
        pass(&world, &refusing, &Hub::new()).await,
        0,
        "not tried again"
    );
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
