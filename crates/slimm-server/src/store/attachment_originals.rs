// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The uploaded original kept beside a compressed attachment, when the space
//! asks for it. The compressed copy is the attachment; the original is only
//! offered as a download.

use super::{Store, now_ms};
use crate::ids::UserId;

/// What the store needs to describe a kept original.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KeptOriginal {
    pub size: i64,
    pub content_type: String,
    pub filename: String,
}

/// Inserts the `attachments` row and the uploader's claim in the caller's transaction.
///
/// Idempotent by content hash: re-uploading existing bytes keeps the first row and its
/// filename, and only refreshes `created_at`, which the orphan sweep measures its grace
/// window from. `key_version` and `is_encrypted` are written as 0 explicitly because v1 is
/// transport-only encryption; the column default 0002 chose is never relied on.
pub(super) async fn insert_attachment(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    sha256: &[u8],
    size: i64,
    content_type: &str,
    filename: &str,
    uploader: Option<UserId>,
) -> Result<(), sqlx::Error> {
    let now = now_ms();
    sqlx::query!(
        "INSERT INTO attachments (sha256, size, content_type, key_version, is_encrypted, filename, created_at)
         VALUES (?, ?, ?, 0, 0, ?, ?)
         ON CONFLICT (sha256) DO UPDATE SET created_at = excluded.created_at",
        sha256,
        size,
        content_type,
        filename,
        now
    )
    .execute(&mut **tx)
    .await?;
    if let Some(uploader) = uploader {
        sqlx::query!(
            "INSERT INTO attachment_uploaders (sha256, uploaded_by, uploaded_at, filename)
             VALUES (?, ?, ?, ?)
             ON CONFLICT (sha256, uploaded_by) DO UPDATE SET filename = excluded.filename",
            sha256,
            uploader,
            now,
            filename
        )
        .execute(&mut **tx)
        .await?;
    }
    Ok(())
}

impl Store {
    /// [`Store::store_attachment`] that also records the original kept beside it. A copy
    /// already holding an original keeps that one.
    pub async fn store_attachment_with_original(
        &self,
        sha256: &[u8],
        size: i64,
        content_type: &str,
        filename: &str,
        uploader: Option<UserId>,
        original: &KeptOriginal,
    ) -> anyhow::Result<()> {
        let mut tx = self.begin_write().await?;
        insert_attachment(&mut tx, sha256, size, content_type, filename, uploader).await?;
        sqlx::query!(
            "UPDATE attachments SET original_size = ?, original_content_type = ?, original_filename = ?
             WHERE sha256 = ? AND original_size = 0",
            original.size,
            original.content_type,
            original.filename,
            sha256
        )
        .execute(&mut *tx)
        .await?;
        tx.commit().await?;
        Ok(())
    }

    /// The kept original of an attachment, if one was kept.
    pub async fn attachment_original(&self, sha256: &[u8]) -> anyhow::Result<Option<KeptOriginal>> {
        let row = sqlx::query!(
            r#"SELECT original_size AS "size!", original_content_type AS "content_type!",
                      original_filename AS "filename!"
               FROM attachments WHERE sha256 = ? AND original_size > 0"#,
            sha256
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.map(|r| KeptOriginal {
            size: r.size,
            content_type: r.content_type,
            filename: r.filename,
        }))
    }
}
