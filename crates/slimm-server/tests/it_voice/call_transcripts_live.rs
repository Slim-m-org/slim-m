// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A call's transcript lines sent live (decision 0113, amended 2026-11-16):
//! only to the people in the call when the line is kept who may read it, in
//! `seq` order, whatever their presence says.

use std::net::SocketAddr;

use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::ids::CallTranscriptId;
use slimm_server::permissions::Permissions;
use slimm_server::store::TranscriptionMode;

use crate::support;
use support::call_audio_world::{Person, Rig};
use support::wait::wait_for;
use support::ws::{Client, connect, read_frame};

async fn socket(rig: &Rig, addr: SocketAddr, who: &Person) -> Client {
    let ctx = rig
        .store
        .authenticate(&who.token)
        .await
        .unwrap()
        .expect("a live session");
    let (ticket, _) = rig.store.mint_ws_ticket(&ctx).await.unwrap();
    connect(addr, &ticket).await
}

async fn hide(rig: &Rig, who: &Person) {
    let body = json!({ "visibility": "hidden" });
    let (status, body) = rig.call(who, "PATCH", "/presence", Some(body)).await;
    assert_eq!(status, StatusCode::OK, "{body}");
}

async fn always_rig(name: &str, people: usize) -> Rig {
    let rig = Rig::start(name, people).await;
    rig.store
        .set_call_transcription(TranscriptionMode::Always)
        .await
        .unwrap();
    rig
}

/// The `call.transcript_line` frames a socket gets before the transcript's end, in arrival order.
async fn lines_until_the_end(ws: &mut Client) -> Vec<Value> {
    let mut lines = Vec::new();
    loop {
        let frame = read_frame(ws).await;
        match frame["type"].as_str() {
            Some("call.transcript_line") => lines.push(frame),
            Some("call.transcript_changed") if frame["ended"] == true => return lines,
            _ => {}
        }
    }
}

async fn next_lines(ws: &mut Client, count: usize) -> Vec<Value> {
    let mut lines = Vec::new();
    while lines.len() < count {
        let frame = read_frame(ws).await;
        if frame["type"] == "call.transcript_line" {
            lines.push(frame);
        }
    }
    lines
}

fn seqs(lines: &[Value]) -> Vec<i64> {
    lines
        .iter()
        .map(|l| l["line"]["seq"].as_i64().unwrap())
        .collect()
}

async fn wait_started(rig: &Rig) -> CallTranscriptId {
    wait_for("the listener to be told to start", || {
        let started = !rig.listener.of_type("start").is_empty();
        async move { started.then_some(()) }
    })
    .await;
    CallTranscriptId(rig.session_id().parse().unwrap())
}

async fn wait_lines(rig: &Rig, id: CallTranscriptId, count: usize) {
    let store = rig.store.clone();
    wait_for("the transcript lines", || {
        let store = store.clone();
        async move {
            let held = store.call_transcript_lines(id, 0, 100).await.unwrap();
            (held.len() >= count).then_some(())
        }
    })
    .await;
}

#[tokio::test]
async fn lines_reach_readers_in_the_call_in_order_and_nobody_else() {
    let rig = always_rig("transcript-live-audience", 5).await;
    let [reader, denied, outside, hidden_in, hidden_out] = [0, 1, 2, 3, 4].map(|n| &rig.people[n]);
    hide(&rig, hidden_in).await;
    hide(&rig, hidden_out).await;
    rig.store
        .set_member_overwrite(
            rig.channel,
            denied.id,
            Permissions::NONE,
            Permissions::VIEW_TRANSCRIPTS,
        )
        .await
        .unwrap();
    let addr = support::ws::serve(rig.state.clone()).await;
    let mut sockets = Vec::new();
    for who in [reader, denied, outside, hidden_in, hidden_out] {
        sockets.push(socket(&rig, addr, who).await);
    }

    for who in [reader, denied, hidden_in] {
        rig.join(who).await;
    }
    let id = wait_started(&rig).await;
    let session = rig.session_id();
    for (who, text) in [(reader, "first"), (hidden_in, "second"), (reader, "third")] {
        rig.listener.segment(&session, &who.id.to_string(), text);
    }
    wait_lines(&rig, id, 3).await;

    let to_reader = next_lines(&mut sockets[0], 3).await;
    assert_eq!(seqs(&to_reader), vec![1, 2, 3], "lines arrive in seq order");
    let first = &to_reader[0];
    assert_eq!(first["transcript_id"], id.to_string());
    assert_eq!(first["channel_id"], rig.channel.to_string());
    assert_eq!(first["line"]["speaker_id"], reader.id.to_string());
    assert_eq!(first["line"]["text"], "first");
    assert_eq!(first["line"]["language"], "en");
    assert_eq!(
        first["line"]["end_at"].as_i64().unwrap() - first["line"]["at"].as_i64().unwrap(),
        1500
    );
    assert_eq!(to_reader[1]["line"]["speaker_id"], hidden_in.id.to_string());

    for who in [reader, denied, hidden_in] {
        rig.leave(who).await;
    }
    assert!(lines_until_the_end(&mut sockets[0]).await.is_empty());
    let to_hidden_in = lines_until_the_end(&mut sockets[3]).await;
    assert_eq!(
        seqs(&to_hidden_in),
        vec![1, 2, 3],
        "a hidden member in the call still gets the lines"
    );
    for (n, why) in [
        (1, "in the call without VIEW_TRANSCRIPTS"),
        (2, "a reader who is not in the call"),
        (4, "a hidden member who is not in the call"),
    ] {
        let leaked = lines_until_the_end(&mut sockets[n]).await;
        assert!(leaked.is_empty(), "{why} got {leaked:?}");
    }
}

#[tokio::test]
async fn someone_who_left_gets_no_line_kept_after_they_left() {
    let rig = always_rig("transcript-live-leaver", 2).await;
    let (leaver, stayer) = (&rig.people[0], &rig.people[1]);
    let addr = support::ws::serve(rig.state.clone()).await;
    let mut leaver_ws = socket(&rig, addr, leaver).await;
    let mut stayer_ws = socket(&rig, addr, stayer).await;
    rig.join(leaver).await;
    rig.join(stayer).await;
    let id = wait_started(&rig).await;
    let session = rig.session_id();

    rig.listener
        .segment(&session, &leaver.id.to_string(), "before I go");
    assert_eq!(seqs(&next_lines(&mut leaver_ws, 1).await), vec![1]);
    rig.leave(leaver).await;
    rig.listener
        .segment(&session, &stayer.id.to_string(), "after you left");
    wait_lines(&rig, id, 2).await;
    assert_eq!(seqs(&next_lines(&mut stayer_ws, 2).await), vec![1, 2]);

    rig.leave(stayer).await;
    let late = lines_until_the_end(&mut leaver_ws).await;
    assert!(late.is_empty(), "the leaver got {late:?}");
}
