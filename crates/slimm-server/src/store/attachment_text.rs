// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Text extracted from attachments, searchable beside message content. The
//! text lives in `attachment_text_fts` only; `attachment_text` marks which
//! attachments were processed, so a file with nothing to extract is not
//! retried. See migration 0152.

use std::collections::HashMap;

use sqlx::{QueryBuilder, Row};

use super::{Store, now_ms};
use crate::ids::MessageId;
use crate::media::to_hex;

/// An attachment waiting for extraction.
#[derive(Debug, Clone)]
pub struct TextCandidate {
    pub sha256: Vec<u8>,
    pub hex: String,
    pub content_type: String,
    pub size: i64,
    /// The name it was first sent under, absent for rows from before 0096.
    pub filename: Option<String>,
}

impl Store {
    /// The newest attachments in live, unencrypted messages that have not been
    /// through extraction yet, so recent uploads become searchable first and
    /// older ones follow as the background pass catches up.
    pub async fn attachments_awaiting_text(
        &self,
        limit: i64,
    ) -> anyhow::Result<Vec<TextCandidate>> {
        let rows = sqlx::query(
            "SELECT a.sha256 AS sha256, a.content_type AS content_type, a.size AS size,
                    (SELECT ma.filename FROM message_attachments ma
                      WHERE ma.sha256 = a.sha256 AND ma.filename IS NOT NULL LIMIT 1) AS filename
             FROM attachments a
             WHERE NOT EXISTS (SELECT 1 FROM attachment_text t WHERE t.sha256 = a.sha256)
               AND EXISTS (SELECT 1 FROM message_attachments ma
                             JOIN messages m ON m.id = ma.message_id
                            WHERE ma.sha256 = a.sha256 AND m.is_encrypted = 0
                              AND m.deleted_at IS NULL)
             ORDER BY a.created_at DESC LIMIT ?",
        )
        .bind(limit)
        .fetch_all(&self.pool)
        .await?;
        rows.into_iter()
            .map(|row| {
                let sha256: Vec<u8> = row.try_get("sha256")?;
                Ok(TextCandidate {
                    hex: to_hex(&sha256),
                    sha256,
                    content_type: row.try_get("content_type")?,
                    size: row.try_get("size")?,
                    filename: row.try_get("filename")?,
                })
            })
            .collect::<Result<_, sqlx::Error>>()
            .map_err(Into::into)
    }

    /// Marks `sha256` as processed, and indexes `text` when there is any.
    /// A no-op if the attachment was swept or processed meanwhile.
    pub async fn record_attachment_text(
        &self,
        sha256: &[u8],
        text: Option<&str>,
    ) -> anyhow::Result<()> {
        let mut tx = self.begin_write().await?;
        let now = now_ms();
        let row = sqlx::query_scalar!(
            r#"INSERT INTO attachment_text (sha256, extracted_at)
               SELECT ?, ? WHERE EXISTS (SELECT 1 FROM attachments WHERE sha256 = ?)
               ON CONFLICT (sha256) DO NOTHING
               RETURNING fts_rowid AS "fts_rowid!: i64""#,
            sha256,
            now,
            sha256,
        )
        .fetch_optional(&mut *tx)
        .await?;
        if let (Some(rowid), Some(text)) = (row, text) {
            sqlx::query!(
                "INSERT INTO attachment_text_fts (rowid, content) VALUES (?, ?)",
                rowid,
                text,
            )
            .execute(&mut *tx)
            .await?;
        }
        tx.commit().await?;
        Ok(())
    }

    /// For each of `message_ids` that matches `query` only through an
    /// attachment, the hex id of the first attachment whose extracted text
    /// matches. A message whose own text matches is left out, since the
    /// attachment is then not why it was found.
    pub async fn attachments_matching_text(
        &self,
        message_ids: &[MessageId],
        query: &str,
    ) -> anyhow::Result<HashMap<MessageId, String>> {
        if message_ids.is_empty() {
            return Ok(HashMap::new());
        }
        let mut builder = QueryBuilder::new(
            "SELECT ma.message_id AS message_id, ma.sha256 AS sha256
             FROM message_attachments ma
             JOIN attachment_text t ON t.sha256 = ma.sha256
             JOIN messages m ON m.id = ma.message_id
             WHERE t.fts_rowid IN (SELECT rowid FROM attachment_text_fts WHERE attachment_text_fts MATCH ",
        );
        builder.push_bind(query.to_owned());
        builder.push(
            ") AND m.fts_rowid NOT IN (SELECT rowid FROM messages_fts WHERE messages_fts MATCH ",
        );
        builder.push_bind(query.to_owned());
        builder.push(") AND ma.message_id IN (");
        let mut separated = builder.separated(", ");
        for id in message_ids {
            separated.push_bind(*id);
        }
        builder.push(") ORDER BY ma.position DESC");
        let mut found = HashMap::new();
        for row in builder.build().fetch_all(&self.pool).await? {
            let sha256: Vec<u8> = row.try_get("sha256")?;
            // Descending by position, so the first attachment wins the overwrite.
            found.insert(row.try_get("message_id")?, to_hex(&sha256));
        }
        Ok(found)
    }
}
