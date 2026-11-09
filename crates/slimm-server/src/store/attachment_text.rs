// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Text extracted from attachments, searchable beside message content. The
//! text lives in `attachment_text_fts` only; `attachment_text` marks which
//! attachments were processed, so a file with nothing to extract is not
//! retried. See migration 0152.

use std::collections::HashMap;
use std::sync::atomic::Ordering;

use sqlx::Row;

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

/// `?1` is the search text and `{ids}` the message ids to check. The messages' own text is probed per
/// candidate row with `NOT EXISTS` rather than `NOT IN`, which would build the whole corpus's hit set first.
const MATCHING_TEXT_SQL: &str = "SELECT ma.message_id AS message_id, ma.sha256 AS sha256 \
    FROM message_attachments ma \
    LEFT JOIN attachment_text t ON t.sha256 = ma.sha256 \
    JOIN messages m ON m.id = ma.message_id \
    WHERE m.is_encrypted = 0 \
      AND (t.fts_rowid IN (SELECT rowid FROM attachment_text_fts WHERE attachment_text_fts MATCH ?1) \
           OR EXISTS (SELECT 1 FROM attachment_name_index n \
                      WHERE n.message_id = ma.message_id AND n.sha256 = ma.sha256 \
                        AND n.fts_rowid IN (SELECT rowid FROM attachment_name_fts \
                                            WHERE attachment_name_fts MATCH ?1))) \
      AND NOT EXISTS (SELECT 1 FROM messages_fts WHERE rowid = m.fts_rowid AND messages_fts MATCH ?1) \
      AND ma.message_id IN ({ids}) \
    ORDER BY ma.position DESC";

impl Store {
    /// Changes whenever a message gains an attachment link, the only way a file becomes
    /// eligible for extraction, so the background pass can tell nothing new is waiting.
    pub fn attachment_link_epoch(&self) -> u64 {
        self.attachment_link_epoch.load(Ordering::Acquire)
    }

    /// Call after the transaction that linked attachments has committed: bumping earlier
    /// lets a pass read the new epoch, miss the uncommitted link, and then record itself caught up.
    pub(in crate::store) fn touch_attachment_links(&self) {
        self.attachment_link_epoch.fetch_add(1, Ordering::AcqRel);
    }

    /// The newest attachments in live, unencrypted messages that have not been
    /// through extraction yet, so recent uploads become searchable first and
    /// older ones follow as the background pass catches up. `skip` holds files
    /// that are backing off, so they cannot occupy the head of the queue.
    pub async fn attachments_awaiting_text(
        &self,
        limit: i64,
        skip: &[Vec<u8>],
    ) -> anyhow::Result<Vec<TextCandidate>> {
        let skip: Vec<String> = skip.iter().map(|sha| to_hex(sha)).collect();
        let rows = sqlx::query(
            "SELECT a.sha256 AS sha256, a.content_type AS content_type, a.size AS size,
                    (SELECT ma.filename FROM message_attachments ma
                      WHERE ma.sha256 = a.sha256 AND ma.filename IS NOT NULL LIMIT 1) AS filename
             FROM attachments a
             WHERE NOT EXISTS (SELECT 1 FROM attachment_text t WHERE t.sha256 = a.sha256)
               AND lower(hex(a.sha256)) NOT IN (SELECT value FROM json_each(?))
               AND EXISTS (SELECT 1 FROM message_attachments ma
                             JOIN messages m ON m.id = ma.message_id
                            WHERE ma.sha256 = a.sha256 AND m.is_encrypted = 0
                              AND m.deleted_at IS NULL)
             ORDER BY a.created_at DESC LIMIT ?",
        )
        .bind(serde_json::to_string(&skip)?)
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

    /// Marks `sha256` as processed, and indexes `text` when there is any and
    /// it is not indexed yet. A no-op if the attachment was swept meanwhile.
    pub async fn record_attachment_text(
        &self,
        sha256: &[u8],
        text: Option<&str>,
    ) -> anyhow::Result<()> {
        let mut tx = self.begin_write().await?;
        let now = now_ms();
        sqlx::query!(
            "INSERT INTO attachment_text (sha256, extracted_at)
             SELECT ?, ? WHERE EXISTS (SELECT 1 FROM attachments WHERE sha256 = ?)
             ON CONFLICT (sha256) DO NOTHING",
            sha256,
            now,
            sha256,
        )
        .execute(&mut *tx)
        .await?;
        // Also covers a marker written earlier, before the text was known.
        if let Some(text) = text {
            sqlx::query(
                "INSERT INTO attachment_text_fts (rowid, content)
                 SELECT t.fts_rowid, ? FROM attachment_text t
                  WHERE t.sha256 = ?
                    AND NOT EXISTS (SELECT 1 FROM attachment_text_fts f WHERE f.rowid = t.fts_rowid)",
            )
            .bind(text)
            .bind(sha256)
            .execute(&mut *tx)
            .await?;
        }
        tx.commit().await?;
        Ok(())
    }

    /// For each of `message_ids` that matches `query` only through an
    /// attachment, the hex id of the first attachment whose extracted text or
    /// file name matches. A message whose own text matches is left out, since the
    /// attachment is then not why it was found.
    pub async fn attachments_matching_text(
        &self,
        message_ids: &[MessageId],
        query: &str,
    ) -> anyhow::Result<HashMap<MessageId, String>> {
        if message_ids.is_empty() {
            return Ok(HashMap::new());
        }
        let placeholders = (2..message_ids.len() + 2)
            .map(|n| format!("?{n}"))
            .collect::<Vec<_>>()
            .join(", ");
        let sql = MATCHING_TEXT_SQL.replace("{ids}", &placeholders);
        let mut matching = sqlx::query(&sql).bind(query.to_owned());
        for id in message_ids {
            matching = matching.bind(*id);
        }
        let mut found = HashMap::new();
        for row in matching.fetch_all(&self.pool).await? {
            let sha256: Vec<u8> = row.try_get("sha256")?;
            // Descending by position, so the first attachment wins the overwrite.
            found.insert(row.try_get("message_id")?, to_hex(&sha256));
        }
        Ok(found)
    }
}
