// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Spoken marks (decision 0113, amended 2026-11-22): a transcribed call acts on
//! "hey space, mark that" only when the Space turned voice commands on before
//! the call's transcript started, and the notice is owed again when they go on.

use std::time::Duration;

use axum::http::StatusCode;
use serde_json::json;
use slimm_server::hub::Event;
use slimm_server::ids::CallTranscriptId;
use slimm_server::store::{MarkKind, MarkSource, TranscriptionMode};

use crate::support;
use support::call_audio_world::{Person, Rig};
use support::wait::wait_for;

/// The runtime re-reads the switch on its 5 s standing check.
const REFRESH: Duration = Duration::from_millis(5_500);

async fn transcribing(name: &str, people: usize) -> Rig {
    let rig = Rig::start(name, people).await;
    rig.store
        .set_call_transcription(TranscriptionMode::Always)
        .await
        .unwrap();
    rig
}

async fn set(rig: &Rig, body: serde_json::Value) -> (StatusCode, serde_json::Value) {
    rig.call(&rig.admin, "PATCH", "/space/settings", Some(body))
        .await
}

async fn start(rig: &Rig, who: &Person) -> CallTranscriptId {
    rig.join(who).await;
    wait_for("the listener to be told to start", || {
        let started = !rig.listener.of_type("start").is_empty();
        async move { started.then_some(()) }
    })
    .await;
    CallTranscriptId(rig.session_id().parse().unwrap())
}

async fn say(rig: &Rig, who: &Person, id: CallTranscriptId, lines: &[&str]) {
    let before = rig
        .store
        .call_transcript_lines(id, 0, 100)
        .await
        .unwrap()
        .len();
    for text in lines {
        rig.listener
            .segment(&rig.session_id(), &who.id.to_string(), text);
    }
    let want = before + lines.len();
    wait_for("the lines", || {
        let store = rig.store.clone();
        async move {
            let held = store.call_transcript_lines(id, 0, 100).await.unwrap();
            (held.len() >= want).then_some(())
        }
    })
    .await;
}

#[tokio::test]
async fn with_the_switch_off_the_phrase_does_nothing() {
    let rig = transcribing("spoken-off", 1).await;
    let who = &rig.people[0];
    let id = start(&rig, who).await;
    tokio::time::sleep(REFRESH).await;
    say(&rig, who, id, &["Hey space, mark that."]).await;
    assert!(
        rig.store
            .call_transcript_marks(id)
            .await
            .unwrap()
            .is_empty()
    );
}

#[tokio::test]
async fn the_phrase_marks_for_the_speaker_once_and_a_wake_arms_the_next_line() {
    let rig = transcribing("spoken-on", 1).await;
    let who = &rig.people[0];
    let (status, body) = set(&rig, json!({ "voice_commands": true })).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["voice_commands"], true);
    assert_eq!(body["voice_command_phrase"], "hey space");
    tokio::time::sleep(REFRESH).await;
    let mut events = rig.state.hub.subscribe();
    let id = start(&rig, who).await;

    say(
        &rig,
        who,
        id,
        &["Hey space, mark that.", "Hey space, mark that again."],
    )
    .await;
    let marks = wait_for("the spoken mark", || {
        let store = rig.store.clone();
        async move {
            let marks = store.call_transcript_marks(id).await.unwrap();
            (!marks.is_empty()).then_some(marks)
        }
    })
    .await;
    assert_eq!(marks.len(), 1, "a second command inside 5 s is ignored");
    let mark = &marks[0];
    assert_eq!(mark.author_id, who.id);
    assert_eq!(
        (mark.kind, mark.source),
        (MarkKind::Mark, MarkSource::Voice)
    );
    assert_eq!(mark.line_seq, Some(1), "it points at the line that said it");
    let line = &rig.store.call_transcript_lines(id, 0, 10).await.unwrap()[0];
    assert_eq!(mark.at, line.at, "stamped with the line's time");
    assert_eq!(line.text, "Hey space, mark that.", "the line stays as said");

    let mut frames = 0;
    while let Ok(event) = events.try_recv() {
        if let Event::CallTranscriptMarkChanged { mark: Some(_), .. } = event {
            frames += 1;
        }
    }
    assert_eq!(frames, 1);
}

#[tokio::test]
async fn a_call_started_before_the_switch_never_acts_on_speech() {
    let rig = transcribing("spoken-before", 1).await;
    let who = &rig.people[0];
    let id = start(&rig, who).await;
    let (status, _) = set(&rig, json!({ "voice_commands": true })).await;
    assert_eq!(status, StatusCode::OK);
    tokio::time::sleep(REFRESH).await;
    say(&rig, who, id, &["Hey space, mark that."]).await;
    assert!(
        rig.store
            .call_transcript_marks(id)
            .await
            .unwrap()
            .is_empty()
    );
}

#[tokio::test]
async fn the_switch_needs_transcription_and_a_good_phrase() {
    let rig = Rig::start("spoken-settings", 0).await;
    let (status, _) = set(&rig, json!({ "voice_commands": true })).await;
    assert_eq!(status, StatusCode::CONFLICT, "transcription is off");
    for bad in ["hey", "hey mark", "hey sp4ce", "one two three four five"] {
        let (status, _) = set(&rig, json!({ "voice_command_phrase": bad })).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{bad}");
    }
    let body = json!({ "call_transcription": "always", "voice_commands": true,
                       "voice_command_phrase": "  Hey   Orbit " });
    let (status, body) = set(&rig, body).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["voice_command_phrase"], "hey orbit");
}

#[tokio::test]
async fn turning_the_switch_on_makes_the_notice_due_again_and_a_phrase_change_does_not() {
    let rig = transcribing("spoken-notice", 1).await;
    let who = &rig.people[0];
    let notice = || async {
        let (_, body) = rig
            .call(who, "GET", "/voice/transcription-notice", None)
            .await;
        body
    };
    let ack = || async {
        let (status, _) = rig
            .call(who, "POST", "/voice/transcription-notice/ack", None)
            .await;
        assert_eq!(status, StatusCode::NO_CONTENT);
    };
    ack().await;
    assert_eq!(notice().await["acknowledged"], true);

    tokio::time::sleep(Duration::from_millis(5)).await;
    set(&rig, json!({ "voice_commands": true })).await;
    let due = notice().await;
    assert_eq!(due["acknowledged"], false, "owed again once they go on");
    assert_eq!(
        (due["voice_commands"].clone(), due["phrase"].clone()),
        (json!(true), json!("hey space"))
    );
    tokio::time::sleep(Duration::from_millis(5)).await;
    ack().await;
    assert_eq!(notice().await["acknowledged"], true);

    set(&rig, json!({ "voice_command_phrase": "hey orbit" })).await;
    assert_eq!(
        notice().await["acknowledged"],
        true,
        "a new phrase alone owes nothing"
    );
    set(&rig, json!({ "voice_commands": true })).await;
    assert_eq!(
        notice().await["acknowledged"],
        true,
        "already on owes nothing"
    );
}
