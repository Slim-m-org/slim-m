// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Marks and notes on a running call's transcript (decision 0113, amended
//! 2026-11-22): who may add, read and remove them, and who is sent them live.

use std::net::SocketAddr;

use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::ids::CallTranscriptId;
use slimm_server::permissions::Permissions;
use slimm_server::store::TranscriptionMode;
use uuid::Uuid;

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

async fn running(name: &str, people: usize) -> (Rig, CallTranscriptId) {
    let rig = Rig::start(name, people).await;
    rig.store
        .set_call_transcription(TranscriptionMode::Always)
        .await
        .unwrap();
    rig.join(&rig.people[0]).await;
    wait_for("the listener to be told to start", || {
        let started = !rig.listener.of_type("start").is_empty();
        async move { started.then_some(()) }
    })
    .await;
    let id = CallTranscriptId(rig.session_id().parse().unwrap());
    (rig, id)
}

fn marks_uri(id: CallTranscriptId) -> String {
    format!("/voice/transcripts/{id}/marks")
}

async fn put_mark(
    rig: &Rig,
    who: &Person,
    id: CallTranscriptId,
    body: Value,
) -> (StatusCode, Value, Uuid) {
    let mark = Uuid::now_v7();
    let uri = format!("{}/{mark}", marks_uri(id));
    let (status, body) = rig.call(who, "PUT", &uri, Some(body)).await;
    (status, body, mark)
}

/// The `call.transcript_mark` frames a socket gets before the transcript's end.
async fn marks_until_the_end(ws: &mut Client) -> Vec<Value> {
    let mut marks = Vec::new();
    loop {
        let frame = read_frame(ws).await;
        match frame["type"].as_str() {
            Some("call.transcript_mark") => marks.push(frame),
            Some("call.transcript_changed") if frame["ended"] == true => return marks,
            _ => {}
        }
    }
}

async fn end_call(rig: &Rig, in_call: &[&Person]) {
    for who in in_call {
        rig.leave(who).await;
    }
}

#[tokio::test]
async fn a_mark_reaches_readers_in_the_call_and_nobody_else() {
    let (rig, id) = running("marks-audience", 4).await;
    let [marker, reader, denied, outside] = [0, 1, 2, 3].map(|n| &rig.people[n]);
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
    for who in [marker, reader, denied, outside] {
        sockets.push(socket(&rig, addr, who).await);
    }
    let admin_ws = socket(&rig, addr, &rig.admin).await;
    for who in [reader, denied] {
        rig.join(who).await;
    }
    rig.listener.segment(
        &rig.session_id(),
        &marker.id.to_string(),
        "the plan is ready",
    );
    wait_for("the line", || {
        let store = rig.store.clone();
        async move {
            let held = store.call_transcript_lines(id, 0, 10).await.unwrap();
            (!held.is_empty()).then_some(())
        }
    })
    .await;

    let note = json!({ "kind": "note", "text": "  ship it friday  " });
    let (status, kept, mark) = put_mark(&rig, marker, id, note.clone()).await;
    assert_eq!(status, StatusCode::CREATED, "{kept}");
    assert_eq!(kept["id"], mark.to_string());
    assert_eq!(kept["author_id"], marker.id.to_string());
    assert_eq!(kept["kind"], "note");
    assert_eq!(kept["text"], "ship it friday", "the note is trimmed");
    assert_eq!(kept["source"], "manual");
    assert_eq!(kept["line_seq"], 1, "it points at the newest line");

    let uri = format!("{}/{mark}", marks_uri(id));
    let (again, repeat) = rig.call(marker, "PUT", &uri, Some(note)).await;
    assert_eq!(again, StatusCode::OK, "a retry is the same mark");
    assert_eq!(repeat, kept);
    let (taken, _) = rig
        .call(reader, "PUT", &uri, Some(json!({ "kind": "mark" })))
        .await;
    assert_eq!(
        taken,
        StatusCode::CONFLICT,
        "another person cannot reuse the id"
    );

    let (status, plain, _) = put_mark(&rig, reader, id, json!({ "kind": "mark" })).await;
    assert_eq!(status, StatusCode::CREATED, "{plain}");
    assert_eq!(plain["text"], Value::Null);

    let (listed, body) = rig.call(outside, "GET", &marks_uri(id), None).await;
    assert_eq!(
        listed,
        StatusCode::OK,
        "a reader outside the call may read them"
    );
    let ids: Vec<&Value> = body["marks"]
        .as_array()
        .unwrap()
        .iter()
        .map(|m| &m["id"])
        .collect();
    assert_eq!(ids, vec![&kept["id"], &plain["id"]], "oldest first");
    let (hidden, _) = rig.call(denied, "GET", &marks_uri(id), None).await;
    assert_eq!(
        hidden,
        StatusCode::NOT_FOUND,
        "no VIEW_TRANSCRIPTS reads nothing"
    );

    end_call(&rig, &[marker, reader, denied]).await;
    for n in [0, 1] {
        let got = marks_until_the_end(&mut sockets[n]).await;
        assert_eq!(got.len(), 2, "everyone in the call who may read gets both");
        assert_eq!(got[0]["transcript_id"], id.to_string());
        assert_eq!(got[0]["mark_id"], mark.to_string());
        assert_eq!(got[0]["mark"]["text"], "ship it friday");
    }
    sockets.push(admin_ws);
    for (n, why) in [
        (2, "in the call without VIEW_TRANSCRIPTS"),
        (3, "a reader outside the call"),
        (4, "an administrator outside the call"),
    ] {
        let leaked = marks_until_the_end(&mut sockets[n]).await;
        assert!(leaked.is_empty(), "{why} got {leaked:?}");
    }
}

#[tokio::test]
async fn only_people_in_a_running_call_may_mark_and_not_twice_in_two_seconds() {
    let (rig, id) = running("marks-who", 2).await;
    let (marker, outside) = (&rig.people[0], &rig.people[1]);
    let mark = json!({ "kind": "mark" });

    let (status, body, _) = put_mark(&rig, outside, id, mark.clone()).await;
    assert_eq!(status, StatusCode::FORBIDDEN, "{body}");
    let (status, _, _) = put_mark(&rig, &rig.admin, id, mark.clone()).await;
    assert_eq!(
        status,
        StatusCode::FORBIDDEN,
        "an admin outside the call cannot mark it"
    );
    for bad in [
        json!({ "kind": "note" }),
        json!({ "kind": "note", "text": "   " }),
        json!({ "kind": "mark", "text": "words" }),
        json!({ "kind": "clip" }),
        json!({ "kind": "note", "text": "x".repeat(501) }),
    ] {
        let (status, _, _) = put_mark(&rig, marker, id, bad.clone()).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{bad}");
    }

    let (first, _, _) = put_mark(&rig, marker, id, mark.clone()).await;
    assert_eq!(first, StatusCode::CREATED);
    let (soon, _, _) = put_mark(&rig, marker, id, mark.clone()).await;
    assert_eq!(soon, StatusCode::TOO_MANY_REQUESTS);

    rig.leave(marker).await;
    wait_for("the transcript to end", || {
        let store = rig.store.clone();
        async move {
            let row = store.call_transcript(id).await.unwrap();
            row.and_then(|t| t.ended_at)
        }
    })
    .await;
    rig.join(marker).await;
    let (ended, _, _) = put_mark(&rig, marker, id, mark).await;
    assert_eq!(
        ended,
        StatusCode::CONFLICT,
        "nothing is added after the call"
    );
}

#[tokio::test]
async fn the_author_and_a_message_moderator_may_remove_a_mark_and_nobody_else() {
    let (rig, id) = running("marks-remove", 3).await;
    let [author, other, denied] = [0, 1, 2].map(|n| &rig.people[n]);
    rig.join(other).await;
    rig.store
        .set_member_overwrite(
            rig.channel,
            denied.id,
            Permissions::NONE,
            Permissions::VIEW_TRANSCRIPTS,
        )
        .await
        .unwrap();
    let (_, _, first) = put_mark(&rig, author, id, json!({ "kind": "mark" })).await;
    let (_, _, second) = put_mark(&rig, other, id, json!({ "kind": "mark" })).await;
    let uri = |mark: Uuid| format!("{}/{mark}", marks_uri(id));

    let (status, _) = rig.call(other, "DELETE", &uri(first), None).await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    let (status, _) = rig.call(denied, "DELETE", &uri(first), None).await;
    assert_eq!(status, StatusCode::NOT_FOUND, "a non-reader learns nothing");
    let (status, _) = rig.call(author, "DELETE", &uri(first), None).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let (status, _) = rig.call(author, "DELETE", &uri(first), None).await;
    assert_eq!(status, StatusCode::NOT_FOUND);

    end_call(&rig, &[author, other]).await;
    let (status, _) = rig.call(&rig.admin, "DELETE", &uri(second), None).await;
    assert_eq!(
        status,
        StatusCode::NO_CONTENT,
        "a moderator may remove one after the call"
    );
    assert!(
        rig.store
            .call_transcript_marks(id)
            .await
            .unwrap()
            .is_empty()
    );
}
