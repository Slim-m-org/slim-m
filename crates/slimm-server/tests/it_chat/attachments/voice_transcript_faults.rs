// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Voice transcripts when the database refuses the write: nothing is left half
//! stored, and the clip waits out its backoff instead of going straight back
//! to the engine. Faults come from triggers, as in `send_retry_repairs`. And when
//! the listener is out, no clip is left shown transcribing.

use std::sync::atomic::Ordering;
use std::time::Duration;

use serde_json::Value;
use slimm_server::hub::{Event, Hub, MessageEvent};
use slimm_server::voice_transcripts::{Failure, VoiceTranscriber};

use crate::attachments::text_search::{World, world};
use crate::attachments::voice_transcripts::{Fake, send_voice, transcript_of};

async fn exec(world: &World, sql: &'static str) {
    sqlx::query(sql).execute(&world.pool).await.unwrap();
}

async fn pass(world: &World, transcriber: &VoiceTranscriber, engine: &Fake) {
    transcriber
        .run_pass(&world.store, &world.media, &Hub::new(), engine)
        .await;
}

#[tokio::test]
async fn a_transcript_that_cannot_be_indexed_is_not_left_ready_and_unsearchable() {
    let world = world().await;
    world
        .store
        .set_transcribe_voice_messages(true)
        .await
        .unwrap();
    let (message, _) = send_voice(&world, 21).await;
    exec(
        &world,
        "CREATE TRIGGER refuse_index BEFORE INSERT ON attachment_text
         BEGIN SELECT RAISE(ABORT, 'disk full'); END",
    )
    .await;
    let engine = Fake::saying("the harbour at noon");
    pass(
        &world,
        &VoiceTranscriber::with_backoff(Duration::from_secs(60)),
        &engine,
    )
    .await;
    assert_eq!(transcript_of(&world, &message).await["status"], "pending");

    exec(&world, "DROP TRIGGER refuse_index").await;
    pass(
        &world,
        &VoiceTranscriber::with_backoff(Duration::from_millis(1)),
        &engine,
    )
    .await;
    assert_eq!(transcript_of(&world, &message).await["status"], "ready");
    assert_eq!(world.search("harbour").await.len(), 1, "and searchable");
}

#[tokio::test]
async fn a_transcript_that_cannot_be_stored_waits_before_the_engine_hears_it_again() {
    let world = world().await;
    world
        .store
        .set_transcribe_voice_messages(true)
        .await
        .unwrap();
    let (message, _) = send_voice(&world, 22).await;
    exec(
        &world,
        "CREATE TRIGGER refuse_finish BEFORE UPDATE ON attachment_transcripts
         BEGIN SELECT RAISE(ABORT, 'disk full'); END",
    )
    .await;
    let engine = Fake::saying("once is enough");
    pass(
        &world,
        &VoiceTranscriber::with_backoff(Duration::from_secs(60)),
        &engine,
    )
    .await;
    assert_eq!(engine.calls.load(Ordering::SeqCst), 1);
    assert_eq!(transcript_of(&world, &message).await["status"], "pending");
}

/// Every transcript status `hub` announced, in order.
fn announced(events: &mut tokio::sync::broadcast::Receiver<Event>) -> Vec<&'static str> {
    let mut seen = Vec::new();
    while let Ok(event) = events.try_recv() {
        if let Event::Message(MessageEvent::VoiceTranscript { status, .. }) = event {
            seen.push(status);
        }
    }
    seen
}

async fn transcribing_on(world: &World) {
    world
        .store
        .set_transcribe_voice_messages(true)
        .await
        .unwrap();
}

#[tokio::test]
async fn a_clip_the_listener_did_not_take_is_announced_as_no_longer_transcribing() {
    let world = world().await;
    transcribing_on(&world).await;
    let (message, _) = send_voice(&world, 23).await;
    let hub = Hub::new();
    let mut events = hub.subscribe_ephemeral();

    let down = Fake::failing(Failure::Unavailable);
    VoiceTranscriber::new()
        .run_pass(&world.store, &world.media, &hub, &down)
        .await;

    assert_eq!(announced(&mut events), ["pending", "none"]);
    assert_eq!(transcript_of(&world, &message).await, Value::Null);
}

/// A mark from before a crash, or from a result that could not be stored, is not this pass's.
#[tokio::test]
async fn a_pending_mark_nothing_will_finish_is_cleared_while_the_listener_is_out() {
    let world = world().await;
    transcribing_on(&world).await;
    let (message, attachment) = send_voice(&world, 24).await;
    sqlx::query(
        "INSERT INTO attachment_transcripts (sha256, status, updated_at)
         SELECT sha256, 'pending', 0 FROM attachments WHERE lower(hex(sha256)) = ?",
    )
    .bind(&attachment)
    .execute(&world.pool)
    .await
    .unwrap();
    assert_eq!(transcript_of(&world, &message).await["status"], "pending");
    let hub = Hub::new();
    let mut events = hub.subscribe_ephemeral();

    let down = Fake::failing(Failure::Unavailable);
    VoiceTranscriber::new()
        .run_pass(&world.store, &world.media, &hub, &down)
        .await;

    assert_eq!(announced(&mut events), ["none"]);
    assert_eq!(transcript_of(&world, &message).await, Value::Null);
}
