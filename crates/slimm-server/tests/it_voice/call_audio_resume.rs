// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The server's `always` transcription across a lost listener, the instant the
//! listener's clock starts, and outcomes that are carried out out of order.

use std::time::Duration;

use slimm_server::call_audio::{runtime, transcript};
use slimm_server::ids::CallTranscriptId;
use slimm_server::store::{TranscriptionMode, VoiceCommands};

use crate::support;
use support::call_audio_world::Rig;
use support::wait::wait_for;

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
}

async fn always_rig(name: &str, people: usize) -> Rig {
    let rig = Rig::start(name, people).await;
    rig.store
        .set_call_transcription(TranscriptionMode::Always)
        .await
        .unwrap();
    rig
}

async fn wait_start_frames(rig: &Rig, count: usize) {
    wait_for("the listener to be told to start", || {
        let have = rig.listener.of_type("start").len();
        async move { (have >= count).then_some(()) }
    })
    .await;
}

#[tokio::test]
async fn a_call_already_running_is_transcribed_again_once_the_listener_is_back() {
    let rig = always_rig("always-resumes", 1).await;
    let a = &rig.people[0];
    rig.join(a).await;
    wait_start_frames(&rig, 1).await;

    rig.listener.hang_up();
    rig.wait_session(None).await;
    wait_start_frames(&rig, 2).await;

    assert!(rig.state.call_audio.view(rig.channel).is_some());
    assert_eq!(rig.listener.include_sets()[1], vec![a.id.to_string()]);
}

#[tokio::test]
async fn segment_times_count_from_the_listener_started_frame() {
    let rig = always_rig("always-anchor", 1).await;
    let a = &rig.people[0];
    rig.join(a).await;
    wait_start_frames(&rig, 1).await;
    let session = rig.session_id();
    let id = CallTranscriptId(session.parse().unwrap());
    let opened = rig.store.call_transcript(id).await.unwrap().unwrap();

    tokio::time::sleep(Duration::from_millis(400)).await;
    rig.listener.started(&session);
    tokio::time::sleep(Duration::from_millis(100)).await;
    rig.listener.segment(&session, &a.id.to_string(), "hello");

    let store = rig.store.clone();
    let line = wait_for("the line", || {
        let store = store.clone();
        async move {
            store
                .call_transcript_lines(id, 0, 10)
                .await
                .unwrap()
                .into_iter()
                .next()
        }
    })
    .await;
    assert!(
        line.at - opened.started_at >= 1_400,
        "the line sits {}ms after consent, past the 400ms the listener took to start",
        line.at - opened.started_at
    );
}

#[tokio::test]
async fn an_ended_outcome_carried_out_before_the_start_leaves_no_open_transcript() {
    let rig = always_rig("always-race", 1).await;
    let a = &rig.people[0];
    let commands = VoiceCommands {
        on: false,
        phrase: String::new(),
    };
    let began = rig
        .state
        .call_audio
        .begin_always(
            (rig.channel, transcript::subject(&commands)),
            &[a.id],
            now_ms(),
        )
        .unwrap();
    let id = CallTranscriptId(began.session_id);
    let ended = rig
        .state
        .call_audio
        .left(rig.channel, a.id, now_ms())
        .expect("the last person leaving ends the session");

    runtime::apply(&rig.state, ended).await;
    runtime::apply(&rig.state, began).await;

    let row = rig.store.call_transcript(id).await.unwrap();
    assert!(
        row.is_none_or(|row| row.ended_at.is_some()),
        "a transcript for a call that is over stays open"
    );
}
