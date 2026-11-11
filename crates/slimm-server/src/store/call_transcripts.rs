// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Call transcripts kept by the server (decision 0113): one row per
//! transcription session, its spoken lines, and the two Space settings that
//! govern them. Only the call-audio runtime writes lines.

use anyhow::Context;
use sqlx::Row;

use super::message_search::{FtsQuery, SearchError};
use super::{Store, now_ms};
use crate::ids::{CallTranscriptId, ChannelId, UserId};

const DAY_MS: i64 = 24 * 60 * 60 * 1000;
/// The longest retention a caller may set, ten years, as for messages.
pub const MAX_TRANSCRIPT_RETENTION_DAYS: i64 = 3650;
/// Transcripts one sweep pass deletes, each in its own transaction.
const SWEEP_BATCH: i64 = 100;
/// Wraps a match in a highlighted search hit; private-use so no real text collides.
pub const HIGHLIGHT_OPEN: char = '\u{E000}';
pub const HIGHLIGHT_CLOSE: char = '\u{E001}';

/// Who is transcribed by the server, set on the Space.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TranscriptionMode {
    Off,
    OnRequest,
    Always,
}

impl TranscriptionMode {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Off => "off",
            Self::OnRequest => "on_request",
            Self::Always => "always",
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        Some(match raw {
            "off" => Self::Off,
            "on_request" => Self::OnRequest,
            "always" => Self::Always,
            _ => return None,
        })
    }
}

#[derive(Debug, Clone)]
pub struct CallTranscript {
    pub id: CallTranscriptId,
    pub channel_id: ChannelId,
    pub started_at: i64,
    pub ended_at: Option<i64>,
    pub mode: String,
    pub started_by: Option<UserId>,
}

#[derive(Debug, Clone)]
pub struct TranscriptLine {
    pub seq: i64,
    pub speaker_id: UserId,
    pub at: i64,
    pub text: String,
}

#[derive(Debug, Clone)]
pub struct TranscriptHit {
    pub transcript_id: CallTranscriptId,
    pub channel_id: ChannelId,
    pub line: TranscriptLine,
    pub highlight: String,
}

/// What opens a transcript row.
pub struct NewTranscript {
    pub id: CallTranscriptId,
    pub channel_id: ChannelId,
    pub started_at: i64,
    pub mode: TranscriptionMode,
    pub started_by: Option<UserId>,
}

impl Store {
    /// The Space's transcription mode; `off` when the row is missing.
    pub async fn call_transcription(&self) -> anyhow::Result<TranscriptionMode> {
        let raw = sqlx::query_scalar!(
            r#"SELECT call_transcription AS "v!: String" FROM space_settings WHERE id = 1"#
        )
        .fetch_optional(&self.pool)
        .await
        .context("read call transcription")?;
        Ok(raw
            .as_deref()
            .and_then(TranscriptionMode::parse)
            .unwrap_or(TranscriptionMode::Off))
    }

    pub async fn set_call_transcription(&self, mode: TranscriptionMode) -> anyhow::Result<()> {
        let (mode, now) = (mode.as_str(), now_ms());
        sqlx::query!(
            "UPDATE space_settings SET call_transcription = ?, updated_at = ? WHERE id = 1",
            mode,
            now
        )
        .execute(&self.pool)
        .await
        .context("set call transcription")?;
        Ok(())
    }

    /// Days a finished transcript is kept; `None` keeps it forever.
    pub async fn call_transcript_retention_days(&self) -> anyhow::Result<Option<i64>> {
        let days = sqlx::query_scalar!(
            r#"SELECT call_transcript_retention_days AS "v: i64" FROM space_settings WHERE id = 1"#
        )
        .fetch_optional(&self.pool)
        .await
        .context("read call transcript retention")?;
        Ok(days.flatten())
    }

    pub async fn set_call_transcript_retention_days(
        &self,
        days: Option<i64>,
    ) -> anyhow::Result<()> {
        let now = now_ms();
        sqlx::query!(
            "UPDATE space_settings SET call_transcript_retention_days = ?, updated_at = ? WHERE id = 1",
            days,
            now
        )
        .execute(&self.pool)
        .await
        .context("set call transcript retention")?;
        Ok(())
    }

    /// When the member acknowledged the notice that the Space transcribes calls.
    pub async fn transcription_notice_acknowledged_at(
        &self,
        user: UserId,
    ) -> anyhow::Result<Option<i64>> {
        let at = sqlx::query_scalar!(
            r#"SELECT transcription_notice_ack_at AS "v: i64" FROM users WHERE id = ?"#,
            user
        )
        .fetch_optional(&self.pool)
        .await
        .context("read transcription notice acknowledgement")?;
        Ok(at.flatten())
    }

    /// Records the acknowledgement once; a repeat keeps the first time.
    pub async fn acknowledge_transcription_notice(&self, user: UserId) -> anyhow::Result<()> {
        let now = now_ms();
        sqlx::query!(
            "UPDATE users SET transcription_notice_ack_at = ?
             WHERE id = ? AND transcription_notice_ack_at IS NULL",
            now,
            user
        )
        .execute(&self.pool)
        .await
        .context("acknowledge transcription notice")?;
        Ok(())
    }

    pub async fn begin_call_transcript(&self, new: &NewTranscript) -> anyhow::Result<()> {
        let mode = new.mode.as_str();
        sqlx::query!(
            "INSERT INTO call_transcripts (id, channel_id, started_at, mode, started_by)
             VALUES (?, ?, ?, ?, ?)",
            new.id,
            new.channel_id,
            new.started_at,
            mode,
            new.started_by
        )
        .execute(&self.pool)
        .await
        .context("begin call transcript")?;
        Ok(())
    }

    pub async fn end_call_transcript(&self, id: CallTranscriptId, at: i64) -> anyhow::Result<()> {
        sqlx::query!(
            "UPDATE call_transcripts SET ended_at = ? WHERE id = ? AND ended_at IS NULL",
            at,
            id
        )
        .execute(&self.pool)
        .await
        .context("end call transcript")?;
        Ok(())
    }

    /// Closes what a stopped process left running, at the last thing it heard.
    pub async fn close_orphaned_call_transcripts(&self) -> anyhow::Result<u64> {
        Ok(sqlx::query!(
            "UPDATE call_transcripts SET ended_at = COALESCE(
                 (SELECT MAX(at) FROM call_transcript_lines WHERE transcript_id = call_transcripts.id),
                 started_at)
             WHERE ended_at IS NULL"
        )
        .execute(&self.pool)
        .await
        .context("close orphaned call transcripts")?
        .rows_affected())
    }

    /// Appends one spoken line and returns its `seq`.
    pub async fn append_call_transcript_line(
        &self,
        id: CallTranscriptId,
        speaker: UserId,
        at: i64,
        text: &str,
    ) -> anyhow::Result<i64> {
        let seq = sqlx::query_scalar!(
            r#"INSERT INTO call_transcript_lines (transcript_id, seq, speaker_id, at, text)
               VALUES (?1, COALESCE((SELECT MAX(seq) FROM call_transcript_lines
                                      WHERE transcript_id = ?1), 0) + 1, ?2, ?3, ?4)
               RETURNING seq AS "seq!: i64""#,
            id,
            speaker,
            at,
            text
        )
        .fetch_one(&self.pool)
        .await
        .context("append call transcript line")?;
        Ok(seq)
    }

    pub async fn call_transcript(
        &self,
        id: CallTranscriptId,
    ) -> anyhow::Result<Option<CallTranscript>> {
        let row = sqlx::query!(
            r#"SELECT id AS "id!: CallTranscriptId", channel_id AS "channel_id!: ChannelId",
                      started_at, ended_at, mode, started_by AS "started_by: UserId"
               FROM call_transcripts WHERE id = ?"#,
            id
        )
        .fetch_optional(&self.pool)
        .await
        .context("read call transcript")?;
        Ok(row.map(|r| CallTranscript {
            id: r.id,
            channel_id: r.channel_id,
            started_at: r.started_at,
            ended_at: r.ended_at,
            mode: r.mode,
            started_by: r.started_by,
        }))
    }

    /// Lines after `after_seq`, oldest first.
    pub async fn call_transcript_lines(
        &self,
        id: CallTranscriptId,
        after_seq: i64,
        limit: i64,
    ) -> anyhow::Result<Vec<TranscriptLine>> {
        let rows = sqlx::query!(
            r#"SELECT seq, speaker_id AS "speaker_id!: UserId", at, text
               FROM call_transcript_lines WHERE transcript_id = ? AND seq > ?
               ORDER BY seq LIMIT ?"#,
            id,
            after_seq,
            limit
        )
        .fetch_all(&self.pool)
        .await
        .context("read call transcript lines")?;
        Ok(rows
            .into_iter()
            .map(|r| TranscriptLine {
                seq: r.seq,
                speaker_id: r.speaker_id,
                at: r.at,
                text: r.text,
            })
            .collect())
    }

    /// The `(id, started_at)` of a channel's transcripts that started at or after `since`.
    pub async fn call_transcripts_since(
        &self,
        channel: ChannelId,
        since: i64,
    ) -> anyhow::Result<Vec<(CallTranscriptId, i64)>> {
        let rows = sqlx::query!(
            r#"SELECT id AS "id!: CallTranscriptId", started_at FROM call_transcripts
               WHERE channel_id = ? AND started_at >= ? ORDER BY started_at DESC"#,
            channel,
            since
        )
        .fetch_all(&self.pool)
        .await
        .context("list call transcripts")?;
        Ok(rows.into_iter().map(|r| (r.id, r.started_at)).collect())
    }

    /// Removes a transcript with its lines and index rows; false when there was none.
    pub async fn delete_call_transcript(&self, id: CallTranscriptId) -> anyhow::Result<bool> {
        let mut tx = self.begin_write().await?;
        sqlx::query!(
            "DELETE FROM call_transcript_lines WHERE transcript_id = ?",
            id
        )
        .execute(&mut *tx)
        .await?;
        let gone = sqlx::query!("DELETE FROM call_transcripts WHERE id = ?", id)
            .execute(&mut *tx)
            .await?
            .rows_affected();
        tx.commit().await?;
        Ok(gone > 0)
    }

    /// Deletes finished transcripts past the retention window, a batch at a time.
    pub async fn sweep_call_transcripts(&self, now: i64) -> anyhow::Result<u64> {
        let Some(days) = self.call_transcript_retention_days().await? else {
            return Ok(0);
        };
        let cutoff = now - days * DAY_MS;
        let mut removed = 0;
        loop {
            let batch = sqlx::query_scalar!(
                r#"SELECT id AS "id!: CallTranscriptId" FROM call_transcripts
                   WHERE ended_at IS NOT NULL AND ended_at < ? LIMIT ?"#,
                cutoff,
                SWEEP_BATCH
            )
            .fetch_all(&self.pool)
            .await?;
            if batch.is_empty() {
                return Ok(removed);
            }
            for id in batch {
                removed += u64::from(self.delete_call_transcript(id).await?);
            }
        }
    }

    /// Lines matching `query` in `channels`, newest first; `before_at` is an exclusive cursor.
    pub async fn search_call_transcripts(
        &self,
        channels: &[ChannelId],
        query: &FtsQuery,
        before_at: Option<i64>,
        limit: i64,
    ) -> Result<Vec<TranscriptHit>, SearchError> {
        if channels.is_empty() {
            return Ok(Vec::new());
        }
        let mut builder = sqlx::QueryBuilder::new(
            "SELECT l.transcript_id, t.channel_id, l.seq, l.speaker_id, l.at, l.text,
                    highlight(call_transcript_lines_fts, 0, ",
        );
        builder.push_bind(HIGHLIGHT_OPEN.to_string());
        builder.push(", ");
        builder.push_bind(HIGHLIGHT_CLOSE.to_string());
        builder.push(
            ") AS highlight
             FROM call_transcript_lines_fts f
             JOIN call_transcript_lines l ON l.id = f.rowid
             JOIN call_transcripts t ON t.id = l.transcript_id
             WHERE call_transcript_lines_fts MATCH ",
        );
        builder.push_bind(query.as_str().to_owned());
        builder.push(" AND t.channel_id IN (");
        let mut ids = builder.separated(", ");
        for channel in channels {
            ids.push_bind(*channel);
        }
        builder.push(")");
        if let Some(before) = before_at {
            builder.push(" AND l.at < ");
            builder.push_bind(before);
        }
        builder.push(" ORDER BY l.at DESC, l.transcript_id DESC, l.seq DESC LIMIT ");
        builder.push_bind(limit);
        let rows = builder.build().fetch_all(&self.pool).await?;
        rows.into_iter()
            .map(|row| -> Result<TranscriptHit, sqlx::Error> {
                Ok(TranscriptHit {
                    transcript_id: row.try_get("transcript_id")?,
                    channel_id: row.try_get("channel_id")?,
                    line: TranscriptLine {
                        seq: row.try_get("seq")?,
                        speaker_id: row.try_get("speaker_id")?,
                        at: row.try_get("at")?,
                        text: row.try_get("text")?,
                    },
                    highlight: row.try_get("highlight")?,
                })
            })
            .collect::<Result<Vec<_>, _>>()
            .map_err(SearchError::from)
    }
}
