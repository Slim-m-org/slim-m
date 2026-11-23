// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Migration 0213: the call-stats window bound is a range of the speaker index, not a filter over every line.

use sqlx::Row;

use crate::support;

#[tokio::test]
async fn a_speakers_lines_since_a_time_are_a_range_of_one_index() {
    let (_store, pool, _guard) = support::new_store_with_pool("call-stats-plan").await;
    let plan: Vec<String> = sqlx::query(
        "EXPLAIN QUERY PLAN SELECT at FROM call_transcript_lines WHERE speaker_id = ? AND at >= ?",
    )
    .bind(vec![0u8; 16])
    .bind(0i64)
    .fetch_all(&pool)
    .await
    .unwrap()
    .iter()
    .map(|row| row.get("detail"))
    .collect();
    assert!(
        plan.iter().any(
            |step| step.contains("call_transcript_lines_speaker_at_idx (speaker_id=? AND at>?")
        ),
        "{plan:?}"
    );
}
