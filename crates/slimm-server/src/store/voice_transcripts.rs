// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The text of voice messages, written by the background worker in
//! `crate::voice_transcripts`. See migrations 0188 and 0189.

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

/// A voice message waiting to be transcribed.
#[derive(Debug, Clone)]
pub struct VoiceCandidate {
    pub sha256: Vec<u8>,
    pub hex: String,
    pub size: i64,
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

    /// The newest voice messages in live, unencrypted messages with no finished transcript.
    /// `skip` holds the ones backing off.
    pub async fn voice_awaiting_transcript(
        &self,
        limit: i64,
        skip: &[Vec<u8>],
    ) -> anyhow::Result<Vec<VoiceCandidate>> {
        let skip: Vec<String> = skip.iter().map(|sha| to_hex(sha)).collect();
        let skip = serde_json::to_string(&skip)?;
        let rows = sqlx::query!(
            r#"SELECT a.sha256 AS "sha256!: Vec<u8>", a.size AS "size!"
               FROM attachments a
               JOIN attachment_voice v ON v.sha256 = a.sha256
               LEFT JOIN attachment_transcripts t ON t.sha256 = a.sha256
               WHERE (t.sha256 IS NULL OR t.status = 'pending')
                 AND lower(hex(a.sha256)) NOT IN (SELECT value FROM json_each(?))
                 AND EXISTS (SELECT 1 FROM message_attachments ma
                               JOIN messages m ON m.id = ma.message_id
                              WHERE ma.sha256 = a.sha256 AND m.is_encrypted = 0
                                AND m.deleted_at IS NULL)
               ORDER BY a.created_at DESC LIMIT ?"#,
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
            })
            .collect())
    }

    /// Marks the start of work, so readers see "transcribing".
    pub async fn begin_voice_transcript(&self, sha256: &[u8]) -> anyhow::Result<()> {
        let now = now_ms();
        sqlx::query!(
            "INSERT INTO attachment_transcripts (sha256, status, updated_at)
             SELECT ?, 'pending', ? WHERE EXISTS (SELECT 1 FROM attachments WHERE sha256 = ?)
             ON CONFLICT (sha256) DO NOTHING",
            sha256,
            now,
            sha256
        )
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// Settles a transcript and indexes its words for search. A no-op if the blob was swept meanwhile.
    pub async fn finish_voice_transcript(
        &self,
        sha256: &[u8],
        outcome: Result<(&str, Option<&str>), ()>,
    ) -> anyhow::Result<Option<VoiceTranscript>> {
        let (status, text, language) = match outcome {
            Ok((text, language)) => (TranscriptStatus::Ready, text, language),
            Err(()) => (TranscriptStatus::Failed, "", None),
        };
        let (now, status_text) = (now_ms(), status.as_str());
        let written = sqlx::query!(
            "INSERT INTO attachment_transcripts (sha256, status, text, language, updated_at)
             SELECT ?, ?, ?, ?, ? WHERE EXISTS (SELECT 1 FROM attachments WHERE sha256 = ?)
             ON CONFLICT (sha256) DO UPDATE SET status = excluded.status, text = excluded.text,
                 language = excluded.language, updated_at = excluded.updated_at",
            sha256,
            status_text,
            text,
            language,
            now,
            sha256
        )
        .execute(&self.pool)
        .await?
        .rows_affected();
        if written == 0 {
            return Ok(None);
        }
        let indexed = (status == TranscriptStatus::Ready && !text.is_empty()).then_some(text);
        self.record_attachment_text(sha256, indexed).await?;
        Ok(Some(VoiceTranscript {
            status,
            text: text.to_owned(),
        }))
    }

    /// The live, unencrypted messages carrying `sha256`, for telling their readers.
    pub async fn messages_with_attachment(
        &self,
        sha256: &[u8],
    ) -> anyhow::Result<Vec<(ChannelId, MessageId)>> {
        let rows = sqlx::query!(
            r#"SELECT m.channel_id AS "channel_id!: ChannelId", m.id AS "message_id!: MessageId"
               FROM message_attachments ma JOIN messages m ON m.id = ma.message_id
               WHERE ma.sha256 = ? AND m.is_encrypted = 0 AND m.deleted_at IS NULL"#,
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
