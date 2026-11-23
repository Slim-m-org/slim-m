// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What `GET /me/call-stats` costs as one member's kept history grows, and how a bounded window reads it.
//! Measurements: run with `--run-ignored only --release`; `SLIMM_STATS_LINES` sets the size.

use jiff::tz::TimeZone;
use slimm_server::call_stats::Tally;
use slimm_server::ids::{CallTranscriptId, UserId};
use slimm_server::store::{NewTranscript, Store, TranscriptionMode};
use sqlx::{Row, SqlitePool};

use crate::support;
use support::call_audio_world::now_ms;

const DAY: i64 = 24 * 60 * 60 * 1000;
const SPACING_MS: i64 = 30_000;
/// The store's own-lines query, joins and live-channel test included.
const OWN_LINES_PLAN: &str = "EXPLAIN QUERY PLAN SELECT l.transcript_id, l.at, l.end_at, l.language, l.text
     FROM call_transcript_lines l
     JOIN call_transcripts t ON t.id = l.transcript_id
     JOIN channels c ON c.id = t.channel_id
     LEFT JOIN messages tpm ON tpm.id = c.parent_message_id
     LEFT JOIN channels tpc ON tpc.id = tpm.channel_id
     WHERE l.speaker_id = ?1 AND l.end_at IS NOT NULL AND l.at >= ?2 AND (?3 IS NULL OR l.transcript_id = ?3)
       AND c.deleted_at IS NULL AND (c.parent_message_id IS NULL OR
           (tpm.deleted_at IS NULL AND tpc.id IS NOT NULL AND tpc.deleted_at IS NULL))";

fn lines() -> i64 {
    std::env::var("SLIMM_STATS_LINES")
        .ok()
        .and_then(|n| n.parse().ok())
        .unwrap_or(100_000)
}

async fn seed(store: &Store, pool: &SqlitePool, speaker: UserId, count: i64, now: i64) {
    let channel = store.create_channel("hangout", "voice").await.unwrap().id;
    let id = CallTranscriptId::generate();
    let started = now - count * SPACING_MS;
    let new = NewTranscript {
        id,
        channel_id: channel,
        started_at: started,
        mode: TranscriptionMode::Always,
        started_by: None,
    };
    store.begin_call_transcript(&new).await.unwrap();
    sqlx::query(
        "WITH RECURSIVE n(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM n WHERE i < ?4 - 1)
         INSERT INTO call_transcript_lines (transcript_id, seq, speaker_id, at, end_at, language, text)
         SELECT ?1, i, ?2, ?3 + i * ?5, ?3 + i * ?5 + 3000, 'en',
                'so we shipped it, you know, and it was actually fine' FROM n",
    )
    .bind(id)
    .bind(speaker)
    .bind(started)
    .bind(count)
    .bind(SPACING_MS)
    .execute(pool)
    .await
    .unwrap();
}

async fn read(store: &Store, speaker: UserId, days: Option<i64>, now: i64) -> (usize, u128) {
    let from = days.map_or(0, |d| now - d * DAY);
    let started = std::time::Instant::now();
    let mut tally = Tally::new(TimeZone::UTC);
    let mut rows = 0;
    store
        .for_each_own_call_line(speaker, from, None, |line| {
            rows += 1;
            tally.add(&line);
        })
        .await
        .unwrap();
    drop(tally.finish(false));
    (rows, started.elapsed().as_millis())
}

#[tokio::test]
#[ignore = "a measurement: SLIMM_STATS_LINES lines (default 100,000), run with --run-ignored only"]
async fn reading_a_long_history_and_a_window_of_it() {
    let (store, pool, _guard) = support::new_store_with_pool("stats-scale").await;
    let speaker = store.create_user("ada", "Ada").await.unwrap().id;
    let now = now_ms();
    let count = lines();
    seed(&store, &pool, speaker, count, now).await;

    let plan: Vec<String> = sqlx::query(OWN_LINES_PLAN)
        .bind(speaker)
        .bind(now - 7 * DAY)
        .bind(None::<CallTranscriptId>)
        .fetch_all(&pool)
        .await
        .unwrap()
        .iter()
        .map(|row| row.get("detail"))
        .collect();
    eprintln!("{count} lines; plan: {plan:?}");
    for days in [None, Some(90), Some(30), Some(7)] {
        let (rows, ms) = read(&store, speaker, days, now).await;
        eprintln!("days={days:?}: {rows} rows in {ms} ms");
    }
}
