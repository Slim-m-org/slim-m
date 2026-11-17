// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The text of voice messages, written by the background worker in
//! `crate::voice_transcripts`. See migrations 0188, 0189 and 0191. One per blob, since the same
//! bytes say the same words, but only a link that is a voice message shows it (0194).

use anyhow::Context;

use super::{Store, now_ms};
use crate::ids::{ChannelId, MessageId};
use crate::media::to_hex;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TranscriptStatus {
    Pending,
    Ready,
    Failed,
}

impl TranscriptStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Pending => "pending",
            Self::Ready => "ready",
            Self::Failed => "failed",
        }
    }

    pub(super) fn parse(raw: &str) -> Option<Self> {
        match raw {
            "pending" => Some(Self::Pending),
            "ready" => Some(Self::Ready),
            "failed" => Some(Self::Failed),
            _ => None,
        }
    }
}

/// What a reader sees under a voice message.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VoiceTranscript {
    pub status: TranscriptStatus,
    pub text: String,
}

impl VoiceTranscript {
    pub(super) fn from_columns(status: Option<String>, text: Option<String>) -> Option<Self> {
        Some(Self {
            status: TranscriptStatus::parse(&status?)?,
            text: text.unwrap_or_default(),
        })
    }
}

/// How one attempt at a voice transcript ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TranscriptOutcome<'a> {
    Heard {
        text: &'a str,
        language: Option<&'a str>,
    },
    /// The listener refused the clip, so it is never tried again.
    Refused,
    /// The listener kept failing the clip; it is tried again once `retry_at` (ms) passes.
    GaveUp { retry_at: i64 },
}

/// SQL that is true for the `attachment_text` row aliased `t`, read through the link aliased `ma`,
/// unless its words are a voice transcript that link does not show: a plain file, or transcripts off.
pub(super) const TRANSCRIPT_TEXT_SHOWN: &str = "(NOT EXISTS (SELECT 1 FROM attachment_transcripts vt \
     WHERE vt.sha256 = t.sha256) \
     OR (ma.voice_duration_ms IS NOT NULL \
         AND (SELECT transcribe_voice_messages FROM space_settings WHERE id = 1) = 1))";

/// A voice message waiting to be transcribed.
#[derive(Debug, Clone)]
pub struct VoiceCandidate {
    pub sha256: Vec<u8>,
    pub hex: String,
    pub size: i64,
    /// Failed before and now due again, so one more failure gives up again.
    pub given_up: bool,
}

impl Store {
    /// Whether the server transcribes voice messages.
    pub async fn transcribe_voice_messages(&self) -> anyhow::Result<bool> {
        let on = sqlx::query_scalar!(
            r#"SELECT transcribe_voice_messages AS "v!: bool" FROM space_settings WHERE id = 1"#
        )
        .fetch_optional(&self.pool)
        .await
        .context("read the voice transcript setting")?;
        Ok(on.unwrap_or(false))
    }

    pub async fn set_transcribe_voice_messages(&self, on: bool) -> anyhow::Result<()> {
        let now = now_ms();
        sqlx::query!(
            "UPDATE space_settings SET transcribe_voice_messages = ?, updated_at = ? WHERE id = 1",
            on,
            now
        )
        .execute(&self.pool)
        .await
        .context("set the voice transcript setting")?;
        Ok(())
    }

    /// The newest clips some live, unencrypted voice message carries with no finished transcript,
    /// or one given up on whose retry time has come. `skip` holds the ones backing off.
    pub async fn voice_awaiting_transcript(
        &self,
        limit: i64,
        skip: &[Vec<u8>],
    ) -> anyhow::Result<Vec<VoiceCandidate>> {
        let skip: Vec<String> = skip.iter().map(|sha| to_hex(sha)).collect();
        let (skip, now) = (serde_json::to_string(&skip)?, now_ms());
        let rows = sqlx::query!(
            r#"SELECT a.sha256 AS "sha256!: Vec<u8>", a.size AS "size!",
                      t.status IS 'failed' AS "given_up!: bool"
               FROM attachments a
               LEFT JOIN attachment_transcripts t ON t.sha256 = a.sha256
               WHERE a.sha256 IN (SELECT ma.sha256 FROM message_attachments ma
                                    JOIN messages m ON m.id = ma.message_id
                                   WHERE ma.voice_duration_ms IS NOT NULL
                                     AND m.is_encrypted = 0 AND m.deleted_at IS NULL)
                 AND (t.sha256 IS NULL OR t.status = 'pending'
                      OR (t.status = 'failed' AND t.retry_at <= ?))
                 AND lower(hex(a.sha256)) NOT IN (SELECT value FROM json_each(?))
               ORDER BY a.created_at DESC LIMIT ?"#,
            now,
            skip,
            limit
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .into_iter()
            .map(|r| VoiceCandidate {
                hex: to_hex(&r.sha256),
                sha256: r.sha256,
                size: r.size,
                given_up: r.given_up,
            })
            .collect())
    }

    /// Marks the start of work, so readers see "transcribing". False when the clip already had a row.
    pub async fn begin_voice_transcript(&self, sha256: &[u8]) -> anyhow::Result<bool> {
        let now = now_ms();
        let started = sqlx::query!(
            "INSERT INTO attachment_transcripts (sha256, status, updated_at)
             SELECT ?, 'pending', ? WHERE EXISTS (SELECT 1 FROM attachments WHERE sha256 = ?)
             ON CONFLICT (sha256) DO NOTHING",
            sha256,
            now,
            sha256
        )
        .execute(&self.pool)
        .await?
        .rows_affected();
        Ok(started == 1)
    }

    /// Takes back a `pending` mark the listener never acted on, so the message is not shown transcribing.
    pub async fn abandon_voice_transcript(&self, sha256: &[u8]) -> anyhow::Result<()> {
        sqlx::query!(
            "DELETE FROM attachment_transcripts WHERE sha256 = ? AND status = 'pending'",
            sha256
        )
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// Settles a transcript and indexes its words for search, in one write.
    /// A no-op if the blob was swept meanwhile.
    pub async fn finish_voice_transcript(
        &self,
        sha256: &[u8],
        outcome: TranscriptOutcome<'_>,
    ) -> anyhow::Result<Option<VoiceTranscript>> {
        let (status, text, language, retry_at) = match outcome {
            TranscriptOutcome::Heard { text, language } => {
                (TranscriptStatus::Ready, text, language, None)
            }
            TranscriptOutcome::Refused => (TranscriptStatus::Failed, "", None, None),
            TranscriptOutcome::GaveUp { retry_at } => {
                (TranscriptStatus::Failed, "", None, Some(retry_at))
            }
        };
        let (now, status_text) = (now_ms(), status.as_str());
        let mut tx = self.begin_write().await?;
        let written = sqlx::query!(
            "INSERT INTO attachment_transcripts (sha256, status, text, language, updated_at, retry_at)
             SELECT ?, ?, ?, ?, ?, ? WHERE EXISTS (SELECT 1 FROM attachments WHERE sha256 = ?)
             ON CONFLICT (sha256) DO UPDATE SET status = excluded.status, text = excluded.text,
                 language = excluded.language, updated_at = excluded.updated_at,
                 retry_at = excluded.retry_at",
            sha256,
            status_text,
            text,
            language,
            now,
            retry_at,
            sha256
        )
        .execute(&mut *tx)
        .await?
        .rows_affected();
        if written == 0 {
            return Ok(None);
        }
        let indexed = (status == TranscriptStatus::Ready && !text.is_empty()).then_some(text);
        Self::record_attachment_text_in(&mut tx, sha256, indexed).await?;
        tx.commit().await?;
        Ok(Some(VoiceTranscript {
            status,
            text: text.to_owned(),
        }))
    }

    /// The live, unencrypted voice messages carrying `sha256`, for telling their readers.
    pub async fn voice_messages_with_clip(
        &self,
        sha256: &[u8],
    ) -> anyhow::Result<Vec<(ChannelId, MessageId)>> {
        let rows = sqlx::query!(
            r#"SELECT m.channel_id AS "channel_id!: ChannelId", m.id AS "message_id!: MessageId"
               FROM message_attachments ma JOIN messages m ON m.id = ma.message_id
               WHERE ma.sha256 = ? AND ma.voice_duration_ms IS NOT NULL
                 AND m.is_encrypted = 0 AND m.deleted_at IS NULL"#,
            sha256
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .into_iter()
            .map(|r| (r.channel_id, r.message_id))
            .collect())
    }
}
