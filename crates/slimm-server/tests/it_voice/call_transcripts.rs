// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The server transcribing a call (decision 0113): the `always` and
//! `on_request` modes end to end through webhooks, routes and a fake listener,
//! and a module session that still writes nothing.

use axum::http::StatusCode;
use serde_json::json;
use slimm_server::ids::CallTranscriptId;
use slimm_server::store::TranscriptionMode;

use crate::support;
use support::call_audio_world::Rig;
use support::wait::wait_for;

fn transcript_id(rig: &Rig) -> CallTranscriptId {
    CallTranscriptId(rig.session_id().parse().unwrap())
}

async fn wait_lines(rig: &Rig, id: CallTranscriptId, count: usize) -> Vec<String> {
    let store = rig.store.clone();
    wait_for("the transcript lines", || {
        let store = store.clone();
        async move {
            let lines = store.call_transcript_lines(id, 0, 100).await.unwrap();
            (lines.len() >= count).then(|| lines.into_iter().map(|l| l.text).collect())
        }
    })
    .await
}

async fn wait_ended(rig: &Rig, id: CallTranscriptId) -> i64 {
    let store = rig.store.clone();
    wait_for("the transcript to end", || {
        let store = store.clone();
        async move {
            store
                .call_transcript(id)
                .await
                .unwrap()
                .and_then(|t| t.ended_at)
        }
    })
    .await
}

async fn wait_start_frames(rig: &Rig, count: usize) {
    wait_for("the listener to be told to start", || {
        let have = rig.listener.of_type("start").len();
        async move { (have >= count).then_some(()) }
    })
    .await;
}

async fn always_rig(name: &str, people: usize) -> Rig {
    let rig = Rig::start(name, people).await;
    rig.store
        .set_call_transcription(TranscriptionMode::Always)
        .await
        .unwrap();
    rig
}

#[tokio::test]
async fn always_mode_starts_at_the_first_join_writes_lines_and_ends_with_the_call() {
    let rig = always_rig("transcript-always", 2).await;
    let (a, b) = (&rig.people[0], &rig.people[1]);
    let mut events = rig.state.hub.subscribe();

    rig.join(a).await;
    wait_start_frames(&rig, 1).await;
    assert_eq!(rig.listener.include_sets(), vec![vec![a.id.to_string()]]);
    rig.join(b).await;
    wait_for("the second include", || {
        let n = rig.listener.of_type("include").len();
        async move { (n >= 1).then_some(()) }
    })
    .await;
    let mut both = vec![a.id.to_string(), b.id.to_string()];
    both.sort();
    assert_eq!(rig.listener.include_sets()[1], both);

    let id = transcript_id(&rig);
    let row = rig.store.call_transcript(id).await.unwrap().unwrap();
    assert_eq!(row.mode, "always");
    assert_eq!(row.started_by, None);
    assert_eq!(row.ended_at, None);

    let session = rig.session_id();
    rig.listener
        .segment(&session, &a.id.to_string(), "hello everyone");
    rig.listener
        .segment(&session, &b.id.to_string(), "hi there");
    assert_eq!(wait_lines(&rig, id, 2).await.len(), 2);
    let lines = rig.store.call_transcript_lines(id, 0, 10).await.unwrap();
    assert_eq!((lines[0].seq, lines[1].seq), (1, 2));

    rig.leave(a).await;
    rig.leave(b).await;
    rig.wait_session(None).await;
    wait_ended(&rig, id).await;

    let mut kinds = Vec::new();
    while let Ok(event) = events.try_recv() {
        let shown = format!("{event:?}");
        assert!(
            !shown.contains("hello everyone"),
            "a line was published: {shown}"
        );
        kinds.push(shown);
    }
    assert!(
        kinds
            .iter()
            .any(|k| k.contains("CallTranscriptChanged") && k.contains("ended: false"))
    );
    assert!(
        kinds
            .iter()
            .any(|k| k.contains("CallTranscriptChanged") && k.contains("ended: true"))
    );
}

#[tokio::test]
async fn always_mode_never_includes_a_bot_and_a_session_refuses_a_stop() {
    let rig = always_rig("transcript-always-bot", 1).await;
    let a = &rig.people[0];
    rig.join(a).await;
    wait_start_frames(&rig, 1).await;
    rig.join_raw(&rig.bot.to_string()).await;
    let sets = rig.listener.include_sets();
    assert!(sets.iter().flatten().all(|id| *id != rig.bot.to_string()));

    let view = rig.status(a).await;
    assert_eq!(view["session"]["mode"], "always");
    assert_eq!(view["session"]["module_id"], "server");
    assert_eq!(view["session"]["asked_by"], serde_json::Value::Null);
    assert_eq!(rig.stop(a).await, StatusCode::CONFLICT);
    let (status, _) = rig.answer(a, false).await;
    assert_eq!(status, StatusCode::CONFLICT);
    assert!(rig.state.call_audio.view(rig.channel).is_some());

    let (status, _) = rig.ask(a).await;
    assert_eq!(status, StatusCode::CONFLICT, "one session per call");
}

#[tokio::test]
async fn on_request_needs_everyones_yes_before_anything_is_kept() {
    let rig = Rig::start("transcript-on-request", 2).await;
    let (a, b) = (&rig.people[0], &rig.people[1]);
    let uri = format!("/channels/{}/voice/transcript", rig.channel);
    rig.join(a).await;
    rig.join(b).await;

    let (status, _) = rig.call(a, "POST", &uri, None).await;
    assert_eq!(status, StatusCode::CONFLICT, "off by default");
    rig.store
        .set_call_transcription(TranscriptionMode::OnRequest)
        .await
        .unwrap();

    let (status, body) = rig.call(a, "POST", &uri, None).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["session"]["status"], "asking");
    assert_eq!(body["session"]["mode"], "on_request");
    assert_eq!(body["session"]["module_id"], "server");
    assert_eq!(body["session"]["asked_by"], a.id.to_string());
    assert!(rig.listener.of_type("start").is_empty());
    let kept = rig
        .store
        .call_transcripts_since(rig.channel, 0)
        .await
        .unwrap();
    assert!(kept.is_empty(), "nothing is kept before everyone agreed");

    rig.answer(b, true).await;
    rig.wait_session(Some("on")).await;
    wait_start_frames(&rig, 1).await;
    let id = transcript_id(&rig);
    let row = rig.store.call_transcript(id).await.unwrap().unwrap();
    assert_eq!(
        (row.mode.as_str(), row.started_by),
        ("on_request", Some(a.id))
    );

    rig.listener
        .segment(&rig.session_id(), &b.id.to_string(), "said after yes");
    wait_lines(&rig, id, 1).await;
    assert_eq!(rig.stop(b).await, StatusCode::NO_CONTENT);
    wait_ended(&rig, id).await;
}

#[tokio::test]
async fn a_no_keeps_nothing() {
    let rig = Rig::start("transcript-on-request-no", 2).await;
    let (a, b) = (&rig.people[0], &rig.people[1]);
    rig.store
        .set_call_transcription(TranscriptionMode::OnRequest)
        .await
        .unwrap();
    rig.join(a).await;
    rig.join(b).await;
    let uri = format!("/channels/{}/voice/transcript", rig.channel);
    rig.call(a, "POST", &uri, None).await;
    rig.answer(b, false).await;
    rig.wait_session(None).await;
    let kept = rig
        .store
        .call_transcripts_since(rig.channel, 0)
        .await
        .unwrap();
    assert!(kept.is_empty());
}

#[tokio::test]
async fn a_module_session_still_writes_no_text_anywhere() {
    let rig = Rig::start("transcript-module-writes-nothing", 2).await;
    let (a, b) = (&rig.people[0], &rig.people[1]);
    rig.join(a).await;
    rig.join(b).await;
    rig.ask(a).await;
    rig.answer(b, true).await;
    rig.wait_session(Some("on")).await;
    wait_start_frames(&rig, 1).await;
    rig.listener
        .segment(&rig.session_id(), &a.id.to_string(), "module only");
    rig.recorded(2).await;

    let kept = rig
        .store
        .call_transcripts_since(rig.channel, 0)
        .await
        .unwrap();
    assert!(kept.is_empty());
    let body = rig.status(a).await;
    assert_eq!(
        body["session"]["module_id"],
        support::call_audio_world::MODULE
    );
    assert!(body["session"].get("mode").is_none());
    assert_eq!(body["transcription"], json!("off"));
}
