// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The caller's own transcript lines for the talk statistics, streamed one at a time.

use anyhow::Context;
use futures_util::StreamExt;
use sqlx::Row;

use super::Store;
use super::export_scope::{live_channel, parent_joins};
use crate::call_stats::StatLine;
use crate::ids::{CallTranscriptId, UserId};

// Only lines with an end time, so a line kept before 0195 never guesses a duration.
const OWN_LINES: &str = concat!(
    "SELECT l.transcript_id, l.at, l.end_at, l.language, l.text
     FROM call_transcript_lines l
     JOIN call_transcripts t ON t.id = l.transcript_id
     JOIN channels c ON c.id = t.channel_id ",
    parent_joins!(),
    " WHERE l.speaker_id = ?1 AND l.end_at IS NOT NULL AND l.at >= ?2
       AND (?3 IS NULL OR l.transcript_id = ?3) AND ",
    live_channel!(),
);

impl Store {
    /// Hands `each` every line `user` spoke on a live channel since `from`, in one transcript when `only` is set.
    pub async fn for_each_own_call_line(
        &self,
        user: UserId,
        from: i64,
        only: Option<CallTranscriptId>,
        mut each: impl FnMut(StatLine<'_>),
    ) -> anyhow::Result<()> {
        let mut rows = sqlx::query(OWN_LINES)
            .bind(user)
            .bind(from)
            .bind(only)
            .fetch(&self.pool);
        while let Some(row) = rows.next().await {
            let row = row.context("read own call line")?;
            let transcript: Vec<u8> = row.try_get("transcript_id")?;
            let language: Option<String> = row.try_get("language")?;
            let text: String = row.try_get("text")?;
            each(StatLine {
                transcript: transcript
                    .try_into()
                    .map_err(|_| anyhow::anyhow!("transcript id is not 16 bytes"))?,
                at: row.try_get("at")?,
                end_at: row.try_get("end_at")?,
                language: language.as_deref(),
                text: &text,
            });
        }
        Ok(())
    }
}
