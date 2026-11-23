// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Marks and notes on a call transcript (decision 0113, amended 2026-11-22). They
//! live and die with their transcript: whoever may read it may read them.

use anyhow::Context;

use super::Store;
use crate::ids::{CallTranscriptId, CallTranscriptMarkId, UserId};

/// The most marks one transcript holds; a long call is not a notebook.
pub const MAX_MARKS_PER_TRANSCRIPT: i64 = 500;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MarkKind {
    Mark,
    Note,
}

impl MarkKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Mark => "mark",
            Self::Note => "note",
        }
    }

    fn parse(raw: &str) -> Self {
        if raw == "note" {
            Self::Note
        } else {
            Self::Mark
        }
    }
}

/// How a mark was made: said aloud with the wake phrase, or with the button or a hotkey.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MarkSource {
    Voice,
    Manual,
}

impl MarkSource {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Voice => "voice",
            Self::Manual => "manual",
        }
    }

    fn parse(raw: &str) -> Self {
        if raw == "voice" {
            Self::Voice
        } else {
            Self::Manual
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TranscriptMark {
    pub id: CallTranscriptMarkId,
    pub transcript_id: CallTranscriptId,
    pub author_id: UserId,
    pub at: i64,
    /// The newest line kept when the mark was made, which it points at; `None` before the first.
    pub line_seq: Option<i64>,
    pub kind: MarkKind,
    pub text: Option<String>,
    pub source: MarkSource,
}

pub struct NewMark<'a> {
    pub id: CallTranscriptMarkId,
    pub transcript_id: CallTranscriptId,
    pub author: UserId,
    pub at: i64,
    pub kind: MarkKind,
    pub text: Option<&'a str>,
    pub source: MarkSource,
    /// The author's previous mark on this transcript must be at least this old.
    pub gap_ms: i64,
}

#[derive(Debug)]
pub enum PutMark {
    Created(TranscriptMark),
    /// A retry of a mark already kept: the stored one, unchanged.
    Existing(TranscriptMark),
    /// The id is another person's or another transcript's mark.
    IdTaken,
    Full,
    /// The author marked less than `gap_ms` ago; retry after this many milliseconds.
    TooSoon(i64),
}

struct Row {
    id: CallTranscriptMarkId,
    transcript_id: CallTranscriptId,
    author_id: UserId,
    at: i64,
    line_seq: Option<i64>,
    kind: String,
    text: Option<String>,
    source: String,
}

impl From<Row> for TranscriptMark {
    fn from(r: Row) -> Self {
        Self {
            id: r.id,
            transcript_id: r.transcript_id,
            author_id: r.author_id,
            at: r.at,
            line_seq: r.line_seq,
            kind: MarkKind::parse(&r.kind),
            text: r.text,
            source: MarkSource::parse(&r.source),
        }
    }
}

impl Store {
    /// Keeps a mark once; a retry with the same id answers with what was kept.
    pub async fn put_call_transcript_mark(
        &self,
        new: &NewMark<'_>,
        now: i64,
    ) -> anyhow::Result<PutMark> {
        let mut tx = self.begin_write().await?;
        if let Some(found) = self.mark_in(&mut tx, new.id).await? {
            let same = found.transcript_id == new.transcript_id && found.author_id == new.author;
            return Ok(if same {
                PutMark::Existing(found)
            } else {
                PutMark::IdTaken
            });
        }
        let held = sqlx::query!(
            r#"SELECT COUNT(*) AS "count!: i64",
                      (SELECT MAX(created_at) FROM call_transcript_marks
                        WHERE transcript_id = ?1 AND author_id = ?2) AS "last: i64"
               FROM call_transcript_marks WHERE transcript_id = ?1"#,
            new.transcript_id,
            new.author
        )
        .fetch_one(&mut *tx)
        .await
        .context("count call transcript marks")?;
        if held.count >= MAX_MARKS_PER_TRANSCRIPT {
            return Ok(PutMark::Full);
        }
        if let Some(last) = held.last
            && now - last < new.gap_ms
        {
            return Ok(PutMark::TooSoon(new.gap_ms - (now - last)));
        }
        let (kind, source) = (new.kind.as_str(), new.source.as_str());
        sqlx::query!(
            "INSERT INTO call_transcript_marks
                 (id, transcript_id, author_id, at, line_seq, kind, text, source, created_at)
             VALUES (?1, ?2, ?3, ?4,
                     (SELECT MAX(seq) FROM call_transcript_lines WHERE transcript_id = ?2),
                     ?5, ?6, ?7, ?8)",
            new.id,
            new.transcript_id,
            new.author,
            new.at,
            kind,
            new.text,
            source,
            now
        )
        .execute(&mut *tx)
        .await
        .context("keep a call transcript mark")?;
        let kept = self
            .mark_in(&mut tx, new.id)
            .await?
            .context("the mark just kept")?;
        tx.commit().await?;
        Ok(PutMark::Created(kept))
    }

    async fn mark_in(
        &self,
        tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
        id: CallTranscriptMarkId,
    ) -> anyhow::Result<Option<TranscriptMark>> {
        let row = sqlx::query_as!(
            Row,
            r#"SELECT id AS "id!: CallTranscriptMarkId", transcript_id AS "transcript_id!: CallTranscriptId",
                      author_id AS "author_id!: UserId", at, line_seq, kind, text, source
               FROM call_transcript_marks WHERE id = ?"#,
            id
        )
        .fetch_optional(&mut **tx)
        .await
        .context("read a call transcript mark")?;
        Ok(row.map(TranscriptMark::from))
    }

    pub async fn call_transcript_mark(
        &self,
        id: CallTranscriptMarkId,
    ) -> anyhow::Result<Option<TranscriptMark>> {
        let row = sqlx::query_as!(
            Row,
            r#"SELECT id AS "id!: CallTranscriptMarkId", transcript_id AS "transcript_id!: CallTranscriptId",
                      author_id AS "author_id!: UserId", at, line_seq, kind, text, source
               FROM call_transcript_marks WHERE id = ?"#,
            id
        )
        .fetch_optional(&self.pool)
        .await
        .context("read a call transcript mark")?;
        Ok(row.map(TranscriptMark::from))
    }

    /// Every mark on a transcript, oldest first.
    pub async fn call_transcript_marks(
        &self,
        transcript: CallTranscriptId,
    ) -> anyhow::Result<Vec<TranscriptMark>> {
        let rows = sqlx::query_as!(
            Row,
            r#"SELECT id AS "id!: CallTranscriptMarkId", transcript_id AS "transcript_id!: CallTranscriptId",
                      author_id AS "author_id!: UserId", at, line_seq, kind, text, source
               FROM call_transcript_marks WHERE transcript_id = ?
               ORDER BY at, id LIMIT ?"#,
            transcript,
            MAX_MARKS_PER_TRANSCRIPT
        )
        .fetch_all(&self.pool)
        .await
        .context("list call transcript marks")?;
        Ok(rows.into_iter().map(TranscriptMark::from).collect())
    }

    /// False when there was no such mark.
    pub async fn delete_call_transcript_mark(
        &self,
        id: CallTranscriptMarkId,
    ) -> anyhow::Result<bool> {
        let gone = sqlx::query!("DELETE FROM call_transcript_marks WHERE id = ?", id)
            .execute(&self.pool)
            .await
            .context("delete a call transcript mark")?
            .rows_affected();
        Ok(gone > 0)
    }
}
