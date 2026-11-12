// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Reading, searching, deleting and expiring the transcripts the server keeps
//! (decision 0113), and the Space settings and once-only notice around them.

use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::ids::{CallTranscriptId, ChannelId, UserId};
use slimm_server::permissions::Permissions;
use slimm_server::store::{NewTranscript, Store, TranscriptionMode, VoiceEventKind};

use crate::support;
use support::call_audio_world::{Person, Rig, now_ms};

const HOUR: i64 = 60 * 60 * 1000;
const DAY: i64 = 24 * HOUR;

async fn keep(
    store: &Store,
    channel: ChannelId,
    started_at: i64,
    ended_at: Option<i64>,
    lines: &[(UserId, &str)],
) -> CallTranscriptId {
    let id = CallTranscriptId::generate();
    let new = NewTranscript {
        id,
        channel_id: channel,
        started_at,
        mode: TranscriptionMode::Always,
        started_by: None,
    };
    store.begin_call_transcript(&new).await.unwrap();
    for (n, (speaker, text)) in lines.iter().enumerate() {
        let at = started_at + 1000 * i64::try_from(n).unwrap();
        store
            .append_call_transcript_line(id, *speaker, at, text)
            .await
            .unwrap();
    }
    if let Some(end) = ended_at {
        store.end_call_transcript(id, end).await.unwrap();
    }
    id
}

async fn get(rig: &Rig, who: &Person, uri: &str) -> (StatusCode, Value) {
    rig.call(who, "GET", uri, None).await
}

async fn deny_transcripts(rig: &Rig, who: &Person) {
    rig.store
        .set_member_overwrite(
            rig.channel,
            who.id,
            Permissions::NONE,
            Permissions::VIEW_TRANSCRIPTS,
        )
        .await
        .unwrap();
}

#[tokio::test]
async fn a_reader_with_the_permission_gets_the_lines_in_pages_and_without_it_a_404() {
    let rig = Rig::start("transcript-read", 2).await;
    let (a, b) = (&rig.people[0], &rig.people[1]);
    let now = now_ms();
    let lines = [(a.id, "one"), (b.id, "two"), (a.id, "three")];
    let id = keep(&rig.store, rig.channel, now - HOUR, Some(now), &lines).await;

    let (status, body) = get(&rig, b, &format!("/voice/transcripts/{id}?limit=2")).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["mode"], "always");
    assert_eq!(body["lines"].as_array().unwrap().len(), 2);
    assert_eq!(body["lines"][0]["speaker_id"], a.id.to_string());
    assert_eq!(body["next_after_seq"], 2);
    let (_, rest) = get(&rig, b, &format!("/voice/transcripts/{id}?after_seq=2")).await;
    assert_eq!(rest["lines"][0]["text"], "three");
    assert_eq!(rest["next_after_seq"], Value::Null);

    deny_transcripts(&rig, b).await;
    let (status, _) = get(&rig, b, &format!("/voice/transcripts/{id}")).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let (status, _) = get(&rig, a, &format!("/voice/transcripts/{id}")).await;
    assert_eq!(
        status,
        StatusCode::OK,
        "only the denied reader is turned away"
    );
}

#[tokio::test]
async fn search_finds_a_line_newest_first_and_skips_channels_the_reader_may_not_read() {
    let rig = Rig::start("transcript-search", 2).await;
    let (a, b) = (&rig.people[0], &rig.people[1]);
    let now = now_ms();
    keep(
        &rig.store,
        rig.channel,
        now - 2 * HOUR,
        Some(now - HOUR),
        &[(a.id, "the budget is late")],
    )
    .await;
    keep(
        &rig.store,
        rig.channel,
        now - HOUR,
        Some(now),
        &[(a.id, "budget again")],
    )
    .await;
    keep(
        &rig.store,
        rig.channel,
        now - HOUR,
        Some(now),
        &[(a.id, "unrelated words")],
    )
    .await;

    let (status, hits) = get(&rig, b, "/search/transcripts?q=budget").await;
    assert_eq!(status, StatusCode::OK, "{hits}");
    let hits = hits.as_array().unwrap();
    assert_eq!(hits.len(), 2);
    assert_eq!(hits[0]["text"], "budget again");
    assert_eq!(hits[1]["text"], "the budget is late");
    assert_eq!(hits[0]["highlight"], "\u{E000}budget\u{E001} again");
    let at = hits[0]["at"].as_i64().unwrap();
    let (_, older) = get(
        &rig,
        b,
        &format!("/search/transcripts?q=budget&before={at}"),
    )
    .await;
    assert_eq!(older.as_array().unwrap().len(), 1);

    deny_transcripts(&rig, b).await;
    let (status, hits) = get(&rig, b, "/search/transcripts?q=budget").await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(hits, json!([]), "a denied channel never appears in search");
    let (_, allowed) = get(&rig, a, "/search/transcripts?q=budget").await;
    assert_eq!(allowed.as_array().unwrap().len(), 2);
    let (status, _) = get(&rig, a, "/search/transcripts?q=").await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn deleting_needs_manage_messages_and_takes_the_search_entries_with_it() {
    let rig = Rig::start("transcript-delete", 1).await;
    let a = &rig.people[0];
    let now = now_ms();
    let id = keep(
        &rig.store,
        rig.channel,
        now - HOUR,
        Some(now),
        &[(a.id, "secret plans")],
    )
    .await;

    let uri = format!("/voice/transcripts/{id}");
    let (status, _) = rig.call(a, "DELETE", &uri, None).await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    let (_, hits) = get(&rig, &rig.admin, "/search/transcripts?q=secret").await;
    assert_eq!(
        hits.as_array().unwrap().len(),
        1,
        "the refused delete changed nothing"
    );

    let (status, _) = rig.call(&rig.admin, "DELETE", &uri, None).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert_eq!(get(&rig, a, &uri).await.0, StatusCode::NOT_FOUND);
    let (_, hits) = get(&rig, &rig.admin, "/search/transcripts?q=secret").await;
    assert_eq!(hits, json!([]));
}

#[tokio::test]
async fn the_calls_list_names_the_transcript_that_started_inside_each_call() {
    let rig = Rig::start("transcript-calls", 2).await;
    let (a, b) = (&rig.people[0], &rig.people[1]);
    let now = now_ms();
    let start = now - 30 * 60 * 1000;
    for (at, kind) in [
        (start, VoiceEventKind::Joined),
        (start + 5 * 60 * 1000, VoiceEventKind::Left),
    ] {
        rig.store
            .record_voice_event(rig.channel, a.id, kind, at)
            .await
            .unwrap();
    }
    let id = keep(
        &rig.store,
        rig.channel,
        start + 1000,
        Some(start + 4 * 60 * 1000),
        &[(a.id, "hi")],
    )
    .await;

    let uri = format!("/channels/{}/voice/calls", rig.channel);
    let (status, body) = get(&rig, b, &uri).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["calls"][0]["transcript_id"], id.to_string());

    deny_transcripts(&rig, b).await;
    let (_, hidden) = get(&rig, b, &uri).await;
    assert!(hidden["calls"][0].get("transcript_id").is_none());
}

#[tokio::test]
async fn the_sweep_removes_finished_transcripts_past_the_window_and_nothing_else() {
    let rig = Rig::start("transcript-sweep", 1).await;
    let a = &rig.people[0];
    let now = now_ms();
    let old = keep(
        &rig.store,
        rig.channel,
        now - 3 * DAY,
        Some(now - 2 * DAY),
        &[(a.id, "ancient history")],
    )
    .await;
    let fresh = keep(
        &rig.store,
        rig.channel,
        now - HOUR,
        Some(now),
        &[(a.id, "fresh news")],
    )
    .await;
    let running = keep(
        &rig.store,
        rig.channel,
        now - 5 * DAY,
        None,
        &[(a.id, "still going")],
    )
    .await;

    rig.store
        .set_call_transcript_retention_days(None)
        .await
        .unwrap();
    let kept_forever = slimm_server::run_transcript_retention_sweep_pass(&rig.store).await;
    assert_eq!(kept_forever, 0, "null keeps everything");

    rig.store
        .set_call_transcript_retention_days(Some(1))
        .await
        .unwrap();
    assert_eq!(
        slimm_server::run_transcript_retention_sweep_pass(&rig.store).await,
        1
    );
    assert!(rig.store.call_transcript(old).await.unwrap().is_none());
    assert!(rig.store.call_transcript(fresh).await.unwrap().is_some());
    assert!(rig.store.call_transcript(running).await.unwrap().is_some());
    let (_, hits) = get(&rig, a, "/search/transcripts?q=ancient").await;
    assert_eq!(hits, json!([]), "the index rows went with the lines");
}

#[tokio::test]
async fn the_settings_are_validated_listener_gated_and_audited() {
    let rig = Rig::start("transcript-settings", 1).await;
    let admin = &rig.admin;
    let patch = |body: Value| rig.call(admin, "PATCH", "/space/settings", Some(body));

    assert_eq!(
        patch(json!({"call_transcription": "sometimes"})).await.0,
        StatusCode::BAD_REQUEST
    );
    assert_eq!(
        patch(json!({"call_transcript_retention_days": 0})).await.0,
        StatusCode::BAD_REQUEST
    );
    assert_eq!(
        patch(json!({"call_transcript_retention_days": 3651}))
            .await
            .0,
        StatusCode::BAD_REQUEST
    );
    let (status, body) = patch(json!({"call_transcription": "on_request"})).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["call_transcription"], "on_request");
    assert_eq!(body["call_transcript_retention_days"], 30, "the default");
    let (_, body) = patch(json!({"call_transcript_retention_days": null})).await;
    assert_eq!(body["call_transcript_retention_days"], Value::Null);
    let (_, body) = patch(json!({"call_transcription": "always"})).await;
    assert_eq!(
        body["call_transcript_retention_days"],
        Value::Null,
        "absent leaves it alone"
    );
    let (_, status_body) = rig
        .call(
            &rig.people[0],
            "GET",
            &format!("/channels/{}/voice/call-audio", rig.channel),
            None,
        )
        .await;
    assert_eq!(status_body["transcription"], "always");

    let (status, _) = rig
        .call(
            &rig.people[0],
            "PATCH",
            "/space/settings",
            Some(json!({"call_transcription": "off"})),
        )
        .await;
    assert_eq!(status, StatusCode::FORBIDDEN);

    let (_, log) = rig.call(admin, "GET", "/space/audit-log", None).await;
    let changes = log
        .as_array()
        .unwrap()
        .iter()
        .filter(|entry| entry["action"] == "space.update")
        .count();
    assert_eq!(
        changes, 3,
        "each accepted change is logged and no refused one is: {log}"
    );
}

#[tokio::test]
async fn a_space_without_a_listener_refuses_to_turn_transcription_on() {
    let (store, _guard) = support::new_store("transcript-no-listener").await;
    let (admin, _) = support::overwrite_harness::register(&store, "root").await;
    let router = support::app::router(store);
    let patch = |body: Value| {
        support::app::call(
            &router,
            "PATCH",
            "/space/settings",
            Some(&admin),
            Some(body),
        )
    };
    assert_eq!(
        patch(json!({"call_transcription": "always"})).await.0,
        StatusCode::CONFLICT
    );
    assert_eq!(
        patch(json!({"call_transcription": "on_request"})).await.0,
        StatusCode::CONFLICT
    );
    let (status, body) = patch(json!({"call_transcription": "off"})).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["call_transcription"], "off");
}

#[tokio::test]
async fn the_notice_is_acknowledged_once_per_member_and_stays_acknowledged() {
    let rig = Rig::start("transcript-notice", 2).await;
    let (a, b) = (&rig.people[0], &rig.people[1]);
    rig.store
        .set_call_transcription(TranscriptionMode::Always)
        .await
        .unwrap();

    let (_, first) = get(&rig, a, "/voice/transcription-notice").await;
    assert_eq!(first, json!({"mode": "always", "acknowledged": false}));
    let ack = || rig.call(a, "POST", "/voice/transcription-notice/ack", None);
    assert_eq!(ack().await.0, StatusCode::NO_CONTENT);
    let at = rig
        .store
        .transcription_notice_acknowledged_at(a.id)
        .await
        .unwrap();
    assert!(at.is_some());
    assert_eq!(ack().await.0, StatusCode::NO_CONTENT, "idempotent");
    assert_eq!(
        rig.store
            .transcription_notice_acknowledged_at(a.id)
            .await
            .unwrap(),
        at,
        "a repeat keeps the first time"
    );

    let (_, again) = get(&rig, a, "/voice/transcription-notice").await;
    assert_eq!(again["acknowledged"], true);
    let (_, other) = get(&rig, b, "/voice/transcription-notice").await;
    assert_eq!(other["acknowledged"], false, "per member");
}
