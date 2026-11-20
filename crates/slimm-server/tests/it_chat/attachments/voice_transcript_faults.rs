// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Voice transcripts when the database refuses the write: nothing is left half
//! stored, and the clip waits out its backoff instead of going straight back
//! to the engine. Faults come from triggers, as in `send_retry_repairs`. When
//! the listener is out, no clip is left shown transcribing, and neither that
//! nor a restart gives a failing clip a fresh set of tries.

use std::sync::atomic::Ordering;
use std::time::Duration;

use serde_json::Value;
use slimm_server::hub::{Event, Hub, MessageEvent};
use slimm_server::voice_transcripts::{Failure, MAX_ATTEMPTS, VoiceTranscriber};

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

/// Each pass runs on a new worker, as after a deploy, so only the database remembers the tries.
async fn restarted_pass(world: &World, engine: &Fake) {
    pass(world, &VoiceTranscriber::new(), engine).await;
}

#[tokio::test]
async fn a_clip_that_keeps_failing_is_given_up_on_though_the_server_restarts_between_tries() {
    let world = world().await;
    transcribing_on(&world).await;
    let (message, _) = send_voice(&world, 25).await;
    let broken = Fake::failing(Failure::Transient);
    for attempt in 1..MAX_ATTEMPTS {
        restarted_pass(&world, &broken).await;
        assert_eq!(
            transcript_of(&world, &message).await["status"],
            "pending",
            "still trying after {attempt}"
        );
    }
    restarted_pass(&world, &broken).await;
    assert_eq!(transcript_of(&world, &message).await["status"], "failed");
    assert_eq!(broken.calls.load(Ordering::SeqCst), MAX_ATTEMPTS as usize);
    let counted: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM voice_transcript_attempts")
        .fetch_one(&world.pool)
        .await
        .unwrap();
    assert_eq!(counted, 0, "a settled clip still holds its count");
}

#[tokio::test]
async fn a_listener_outage_between_tries_does_not_start_the_count_over() {
    let world = world().await;
    transcribing_on(&world).await;
    let (message, _) = send_voice(&world, 26).await;
    let broken = Fake::failing(Failure::Transient);
    for _ in 1..MAX_ATTEMPTS {
        restarted_pass(&world, &broken).await;
    }
    restarted_pass(&world, &Fake::failing(Failure::Unavailable)).await;
    assert_eq!(
        transcript_of(&world, &message).await,
        Value::Null,
        "shown transcribing while the listener is out"
    );
    restarted_pass(&world, &broken).await;
    assert_eq!(transcript_of(&world, &message).await["status"], "failed");
}

#[tokio::test]
async fn a_clip_first_failed_right_after_an_outage_is_shown_transcribing() {
    let world = world().await;
    transcribing_on(&world).await;
    let (message, _) = send_voice(&world, 27).await;
    let transcriber = VoiceTranscriber::with_backoff(Duration::from_millis(1));
    let hub = Hub::new();
    let mut events = hub.subscribe_ephemeral();
    let down = Fake::failing(Failure::Unavailable);
    transcriber
        .run_pass(&world.store, &world.media, &hub, &down)
        .await;
    tokio::time::sleep(Duration::from_millis(5)).await;

    let broken = Fake::failing(Failure::Transient);
    transcriber
        .run_pass(&world.store, &world.media, &hub, &broken)
        .await;

    assert_eq!(broken.calls.load(Ordering::SeqCst), 1, "the probe");
    assert_eq!(announced(&mut events), ["pending", "none", "pending"]);
    assert_eq!(transcript_of(&world, &message).await["status"], "pending");
}

#[tokio::test]
async fn a_clip_too_large_to_send_is_refused_rather_than_offered_forever() {
    let world = world().await;
    transcribing_on(&world).await;
    let (message, attachment) = send_voice(&world, 28).await;
    sqlx::query("UPDATE attachments SET size = ?1 WHERE lower(hex(sha256)) = ?2")
        .bind(64_i64 * 1024 * 1024)
        .bind(&attachment)
        .execute(&world.pool)
        .await
        .unwrap();
    let engine = Fake::saying("never heard");

    restarted_pass(&world, &engine).await;

    assert_eq!(transcript_of(&world, &message).await["status"], "failed");
    assert_eq!(engine.calls.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn a_clip_whose_file_is_gone_is_given_up_on_after_its_tries() {
    let world = world().await;
    transcribing_on(&world).await;
    let (message, attachment) = send_voice(&world, 29).await;
    world.media.delete_attachment(&attachment).await.unwrap();
    let engine = Fake::saying("never heard");

    for _ in 0..MAX_ATTEMPTS {
        restarted_pass(&world, &engine).await;
    }

    assert_eq!(transcript_of(&world, &message).await["status"], "failed");
    assert_eq!(engine.calls.load(Ordering::SeqCst), 0);
}
