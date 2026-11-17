// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Voice transcripts when the database refuses the write: nothing is left half
//! stored, and the clip waits out its backoff instead of going straight back
//! to the engine. Faults come from triggers, as in `send_retry_repairs`.

use std::sync::atomic::Ordering;
use std::time::Duration;

use slimm_server::hub::Hub;
use slimm_server::voice_transcripts::VoiceTranscriber;

use crate::attachments::text_search::{World, world};
use crate::attachments::voice_transcripts::{Fake, send_voice, transcript_of};

async fn exec(world: &World, sql: &str) {
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
