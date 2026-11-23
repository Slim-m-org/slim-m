// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A member's own talk statistics (decision 0113): worked out from their own lines, and shown to no one else.

use axum::http::StatusCode;
use serde_json::Value;
use slimm_server::ids::{CallTranscriptId, ChannelId, UserId};
use slimm_server::permissions::Permissions;
use slimm_server::store::{NewTranscript, NewTranscriptLine, Store, TranscriptionMode};

use crate::support;
use support::call_audio_world::{Person, Rig, now_ms};

const HOUR: i64 = 60 * 60 * 1000;
const DAY: i64 = 24 * HOUR;

struct Said<'a> {
    speaker: UserId,
    secs: i64,
    language: &'a str,
    text: &'a str,
}

fn said<'a>(speaker: UserId, secs: i64, language: &'a str, text: &'a str) -> Said<'a> {
    Said {
        speaker,
        secs,
        language,
        text,
    }
}

async fn keep(
    store: &Store,
    channel: ChannelId,
    started: i64,
    lines: &[Said<'_>],
) -> CallTranscriptId {
    let id = CallTranscriptId::generate();
    let new = NewTranscript {
        id,
        channel_id: channel,
        started_at: started,
        mode: TranscriptionMode::Always,
        started_by: None,
    };
    store.begin_call_transcript(&new).await.unwrap();
    for (n, s) in lines.iter().enumerate() {
        let at = started + 60_000 * i64::try_from(n).unwrap();
        let line = NewTranscriptLine {
            speaker: s.speaker,
            at,
            end_at: Some(at + s.secs * 1000),
            language: Some(s.language),
            text: s.text,
        };
        store.append_call_transcript_line(id, &line).await.unwrap();
    }
    store.end_call_transcript(id, started + HOUR).await.unwrap();
    id
}

async fn stats(rig: &Rig, who: &Person, query: &str) -> (StatusCode, Value) {
    rig.call(who, "GET", &format!("/me/call-stats{query}"), None)
        .await
}

async fn rig(name: &str, people: usize) -> Rig {
    let rig = Rig::start(name, people).await;
    rig.store
        .set_call_transcription(TranscriptionMode::Always)
        .await
        .unwrap();
    rig
}

#[tokio::test]
async fn a_members_numbers_come_only_from_their_own_lines() {
    let rig = rig("stats-own", 2).await;
    let (a, b) = (&rig.people[0], &rig.people[1]);
    let at = now_ms() - 2 * HOUR;
    keep(
        &rig.store,
        rig.channel,
        at,
        &[
            said(a.id, 30, "en", "one two three four"),
            said(b.id, 600, "en", "a secret sentence from the other member"),
        ],
    )
    .await;

    let (status, body) = stats(&rig, a, "").await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["talk_ms"], 30_000);
    assert_eq!(body["words"], 4);
    assert_eq!(body["calls"], 1);
    let text = body.to_string();
    for leak in [
        b.id.to_string(),
        a.id.to_string(),
        "secret".into(),
        "P1".into(),
        "p1".into(),
    ] {
        assert!(!text.contains(&leak), "the response names {leak}: {text}");
    }
    let (_, b_body) = stats(&rig, b, "").await;
    assert_eq!(b_body["talk_ms"], 600_000);
}

#[tokio::test]
async fn nobody_can_ask_for_another_members_numbers() {
    let rig = rig("stats-nobody", 2).await;
    let (a, b) = (&rig.people[0], &rig.people[1]);
    let id = keep(
        &rig.store,
        rig.channel,
        now_ms() - 2 * HOUR,
        &[said(a.id, 30, "en", "one two three four")],
    )
    .await;

    let by_user = format!("?user_id={}&speaker_id={}", a.id, a.id);
    let (status, body) = stats(&rig, b, &by_user).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(
        (body["talk_ms"].as_i64(), body["calls"].as_i64()),
        (Some(0), Some(0))
    );

    let (status, body) = stats(&rig, &rig.admin, &by_user).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(
        body["talk_ms"], 0,
        "an administrator gets only their own lines"
    );
    let (status, body) = stats(&rig, &rig.admin, &format!("?transcript_id={id}")).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(
        body["talk_ms"], 0,
        "reading the call is not reading its speakers' numbers"
    );
}

#[tokio::test]
async fn a_bot_is_refused() {
    let rig = rig("stats-bot", 1).await;
    let bot = rig
        .store
        .create_bot("statbot", "Statbot", Permissions::NONE, rig.admin.id)
        .await
        .unwrap();
    let who = Person {
        id: bot.bot.user_id,
        token: bot.token,
    };
    let (status, _) = stats(&rig, &who, "").await;
    assert_eq!(status, StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn lines_without_an_end_time_and_calls_in_a_deleted_channel_are_skipped() {
    let rig = rig("stats-skips", 1).await;
    let a = &rig.people[0];
    let at = now_ms() - 2 * HOUR;
    let old = CallTranscriptId::generate();
    let new = NewTranscript {
        id: old,
        channel_id: rig.channel,
        started_at: at,
        mode: TranscriptionMode::Always,
        started_by: None,
    };
    rig.store.begin_call_transcript(&new).await.unwrap();
    let line = NewTranscriptLine {
        speaker: a.id,
        at,
        end_at: None,
        language: None,
        text: "before 0195",
    };
    rig.store
        .append_call_transcript_line(old, &line)
        .await
        .unwrap();
    let (_, body) = stats(&rig, a, "").await;
    assert_eq!(
        (body["talk_ms"].as_i64(), body["since"].is_null()),
        (Some(0), true)
    );

    let other = rig
        .store
        .create_channel("second", "voice")
        .await
        .unwrap()
        .id;
    keep(
        &rig.store,
        other,
        at,
        &[said(a.id, 40, "en", "gone with the channel")],
    )
    .await;
    let (_, body) = stats(&rig, a, "").await;
    assert_eq!(body["talk_ms"], 40_000);
    rig.store.delete_channel(other).await.unwrap();
    let (_, body) = stats(&rig, a, "").await;
    assert_eq!(body["talk_ms"], 0);
}

#[tokio::test]
async fn deleting_a_transcript_sweeping_it_or_deleting_the_account_lowers_the_numbers() {
    let rig = rig("stats-lower", 2).await;
    let (a, b) = (&rig.people[0], &rig.people[1]);
    let now = now_ms();
    let deleted = keep(
        &rig.store,
        rig.channel,
        now - 2 * HOUR,
        &[said(a.id, 20, "en", "one two")],
    )
    .await;
    keep(
        &rig.store,
        rig.channel,
        now - 3 * DAY,
        &[said(a.id, 15, "en", "old call")],
    )
    .await;
    keep(
        &rig.store,
        rig.channel,
        now - HOUR * 3,
        &[said(a.id, 10, "en", "three")],
    )
    .await;
    let (_, body) = stats(&rig, a, "").await;
    assert_eq!(body["talk_ms"], 45_000);

    let uri = format!("/voice/transcripts/{deleted}");
    let (status, _) = rig.call(&rig.admin, "DELETE", &uri, None).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let (_, body) = stats(&rig, a, "").await;
    assert_eq!(body["talk_ms"], 25_000);

    rig.store
        .set_call_transcript_retention_days(Some(1))
        .await
        .unwrap();
    rig.store.sweep_call_transcripts(now).await.unwrap();
    let (_, body) = stats(&rig, a, "").await;
    assert_eq!(
        (body["talk_ms"].as_i64(), body["retention_days"].as_i64()),
        (Some(10_000), Some(1))
    );

    keep(
        &rig.store,
        rig.channel,
        now - HOUR,
        &[said(b.id, 50, "en", "four")],
    )
    .await;
    rig.store.delete_account(b.id).await.unwrap();
    let mut left = 0;
    rig.store
        .for_each_own_call_line(b.id, 0, None, |_| left += 1)
        .await
        .unwrap();
    assert_eq!(left, 0, "deleting the account takes its lines");
    let (_, body) = stats(&rig, a, "").await;
    assert_eq!(body["talk_ms"], 10_000);
}

#[tokio::test]
async fn a_single_call_needs_the_per_call_read_and_counts_only_the_callers_lines() {
    let rig = rig("stats-call", 2).await;
    let (a, b) = (&rig.people[0], &rig.people[1]);
    let at = now_ms() - 3 * HOUR;
    let one = keep(
        &rig.store,
        rig.channel,
        at,
        &[said(a.id, 10, "en", "one"), said(b.id, 90, "en", "two")],
    )
    .await;
    keep(
        &rig.store,
        rig.channel,
        at + HOUR,
        &[said(a.id, 20, "en", "three")],
    )
    .await;

    let (status, body) = stats(&rig, a, &format!("?transcript_id={one}")).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(
        (body["talk_ms"].as_i64(), body["calls"].as_i64()),
        (Some(10_000), Some(1))
    );

    rig.store
        .set_member_overwrite(
            rig.channel,
            a.id,
            Permissions::NONE,
            Permissions::VIEW_TRANSCRIPTS,
        )
        .await
        .unwrap();
    let (status, _) = stats(&rig, a, &format!("?transcript_id={one}")).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let (status, _) = stats(
        &rig,
        a,
        &format!("?transcript_id={}", CallTranscriptId::generate()),
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn a_bad_zone_or_window_is_a_400_and_a_zone_moves_the_day_buckets() {
    let rig = rig("stats-400", 1).await;
    let a = &rig.people[0];
    for query in ["?tz=Mars/Base", "?days=0", "?days=3651", "?days=abc"] {
        let (status, _) = stats(&rig, a, query).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{query}");
    }
    let at = now_ms() - 2 * HOUR;
    keep(
        &rig.store,
        rig.channel,
        at,
        &[said(a.id, 20, "en", "one two")],
    )
    .await;
    let (status, body) = stats(&rig, a, "?tz=Pacific/Kiritimati&days=30").await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["buckets"]["size"], "day");
    assert!(!body["buckets"]["items"].as_array().unwrap().is_empty());
    let (_, body) = stats(&rig, a, "?days=200").await;
    assert_eq!(body["buckets"]["size"], "week");
}

#[tokio::test]
async fn a_deployment_with_transcripts_off_reports_nothing() {
    let rig = rig("stats-off", 1).await;
    let a = &rig.people[0];
    keep(
        &rig.store,
        rig.channel,
        now_ms() - 2 * HOUR,
        &[said(a.id, 20, "en", "one two")],
    )
    .await;
    rig.store
        .set_call_transcription(TranscriptionMode::Off)
        .await
        .unwrap();
    let (status, body) = stats(&rig, a, "").await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(
        (body["talk_ms"].as_i64(), body["calls"].as_i64()),
        (Some(0), Some(0))
    );
}

#[tokio::test]
#[ignore = "a measurement: 100,000 lines, run with --run-ignored"]
async fn a_hundred_thousand_own_lines_come_back_quickly() {
    let rig = rig("stats-perf", 1).await;
    let a = &rig.people[0];
    let id = keep(
        &rig.store,
        rig.channel,
        now_ms() - DAY,
        &[said(a.id, 3, "en", "warm up")],
    )
    .await;
    for n in 0..100_000_i64 {
        let at = now_ms() - DAY + n;
        let line = NewTranscriptLine {
            speaker: a.id,
            at,
            end_at: Some(at + 3000),
            language: Some("en"),
            text: "so we shipped it, you know, and it was actually fine",
        };
        rig.store
            .append_call_transcript_line(id, &line)
            .await
            .unwrap();
    }
    let raw = std::time::Instant::now();
    let mut n = 0;
    rig.store
        .for_each_own_call_line(a.id, 0, None, |_| n += 1)
        .await
        .unwrap();
    eprintln!("{n} raw rows in {:?}", raw.elapsed());
    let started = std::time::Instant::now();
    let (status, body) = stats(&rig, a, "").await;
    let took = started.elapsed();
    assert_eq!(status, StatusCode::OK, "{body}");
    eprintln!("100k lines answered in {took:?}");
    assert!(took.as_millis() < 500, "{took:?}");
}
