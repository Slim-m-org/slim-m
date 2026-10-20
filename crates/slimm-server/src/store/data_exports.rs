// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Export jobs: one row per requested archive, from queued to expired.
//!
//! The row is the job's status and the only record of the archive; the file
//! under the media root is named after the row's id. See
//! `docs/data-export-format.md` for what an archive holds.

use sqlx::Row;
use sqlx::sqlite::SqliteRow;

use super::{Store, now_ms};
use crate::ids::{ExportId, UserId};

/// How long a finished archive can be downloaded before it is deleted.
pub const EXPORT_RETENTION_MS: i64 = 24 * 60 * 60 * 1000;
/// The shortest gap between two exports of one kind by one account.
const EXPORT_COOLDOWN_MS: i64 = 10 * 60 * 1000;
/// How long an expired or failed row stays listed before it is deleted.
const EXPORT_ROW_KEEP_MS: i64 = 7 * 24 * 60 * 60 * 1000;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExportKind {
    Member,
    Space,
}

impl ExportKind {
    pub fn as_str(self) -> &'static str {
        match self {
            ExportKind::Member => "member",
            ExportKind::Space => "space",
        }
    }

    fn parse(value: &str) -> Self {
        if value == "space" {
            ExportKind::Space
        } else {
            ExportKind::Member
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExportStatus {
    Queued,
    Running,
    Ready,
    Failed,
    Expired,
}

impl ExportStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            ExportStatus::Queued => "queued",
            ExportStatus::Running => "running",
            ExportStatus::Ready => "ready",
            ExportStatus::Failed => "failed",
            ExportStatus::Expired => "expired",
        }
    }

    fn parse(value: &str) -> Self {
        match value {
            "running" => ExportStatus::Running,
            "ready" => ExportStatus::Ready,
            "failed" => ExportStatus::Failed,
            "expired" => ExportStatus::Expired,
            _ => ExportStatus::Queued,
        }
    }
}

#[derive(Debug, Clone)]
pub struct DataExport {
    pub id: ExportId,
    pub user_id: UserId,
    pub kind: ExportKind,
    pub status: ExportStatus,
    pub processed: i64,
    pub total: i64,
    pub size_bytes: Option<i64>,
    pub error: Option<String>,
    pub created_at: i64,
    pub finished_at: Option<i64>,
    pub expires_at: Option<i64>,
}

impl DataExport {
    fn from_row(row: &SqliteRow) -> Self {
        Self {
            id: row.get("id"),
            user_id: row.get("user_id"),
            kind: ExportKind::parse(row.get("kind")),
            status: ExportStatus::parse(row.get("status")),
            processed: row.get("processed"),
            total: row.get("total"),
            size_bytes: row.get("size_bytes"),
            error: row.get("error"),
            created_at: row.get("created_at"),
            finished_at: row.get("finished_at"),
            expires_at: row.get("expires_at"),
        }
    }

    /// Whether the archive can still be downloaded at `now`.
    pub fn is_downloadable(&self, now: i64) -> bool {
        self.status == ExportStatus::Ready && self.expires_at.is_some_and(|at| at > now)
    }
}

/// Why a job was not started.
#[derive(Debug)]
pub enum CreateExportError {
    /// One of this kind is already queued or running for the account.
    Busy,
    /// The last one started less than the cooldown ago; carries the seconds left.
    TooSoon(u64),
    Internal(anyhow::Error),
}

impl From<sqlx::Error> for CreateExportError {
    fn from(err: sqlx::Error) -> Self {
        CreateExportError::Internal(err.into())
    }
}

const COLUMNS: &str = "id, user_id, kind, status, processed, total, size_bytes, error, \
                       created_at, finished_at, expires_at";

impl Store {
    /// Queues a job unless one of this kind is live or too recent.
    pub async fn create_data_export(
        &self,
        user_id: UserId,
        kind: ExportKind,
    ) -> Result<DataExport, CreateExportError> {
        let now = now_ms();
        let mut tx = self.begin_write().await?;
        let latest = sqlx::query(
            "SELECT status, created_at FROM data_exports
             WHERE user_id = ? AND kind = ? AND status <> 'failed'
             ORDER BY created_at DESC LIMIT 1",
        )
        .bind(user_id)
        .bind(kind.as_str())
        .fetch_optional(&mut *tx)
        .await?;
        if let Some(row) = latest {
            let status = ExportStatus::parse(row.get("status"));
            let created_at: i64 = row.get("created_at");
            if matches!(status, ExportStatus::Queued | ExportStatus::Running) {
                return Err(CreateExportError::Busy);
            }
            let wait = created_at + EXPORT_COOLDOWN_MS - now;
            if wait > 0 {
                return Err(CreateExportError::TooSoon(
                    wait.unsigned_abs().div_ceil(1000),
                ));
            }
        }
        let id = ExportId::generate();
        sqlx::query(
            "INSERT INTO data_exports (id, user_id, kind, status, created_at)
             VALUES (?, ?, ?, 'queued', ?)",
        )
        .bind(id)
        .bind(user_id)
        .bind(kind.as_str())
        .bind(now)
        .execute(&mut *tx)
        .await?;
        tx.commit().await?;
        Ok(DataExport {
            id,
            user_id,
            kind,
            status: ExportStatus::Queued,
            processed: 0,
            total: 0,
            size_bytes: None,
            error: None,
            created_at: now,
            finished_at: None,
            expires_at: None,
        })
    }

    pub async fn data_export(&self, id: ExportId) -> anyhow::Result<Option<DataExport>> {
        let row = sqlx::query(&format!("SELECT {COLUMNS} FROM data_exports WHERE id = ?"))
            .bind(id)
            .fetch_optional(&self.pool)
            .await?;
        Ok(row.as_ref().map(DataExport::from_row))
    }

    /// The account's own jobs, newest first.
    pub async fn data_exports_for(
        &self,
        user_id: UserId,
        limit: i64,
    ) -> anyhow::Result<Vec<DataExport>> {
        let rows = sqlx::query(&format!(
            "SELECT {COLUMNS} FROM data_exports WHERE user_id = ?
             ORDER BY created_at DESC LIMIT ?"
        ))
        .bind(user_id)
        .bind(limit)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows.iter().map(DataExport::from_row).collect())
    }

    pub async fn mark_export_running(&self, id: ExportId) -> anyhow::Result<()> {
        sqlx::query(
            "UPDATE data_exports SET status = 'running' WHERE id = ? AND status = 'queued'",
        )
        .bind(id)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// Records progress; false means the row is gone (the account was deleted).
    pub async fn set_export_progress(
        &self,
        id: ExportId,
        processed: i64,
        total: i64,
    ) -> anyhow::Result<bool> {
        let done = sqlx::query(
            "UPDATE data_exports SET processed = ?, total = ? WHERE id = ? AND status = 'running'",
        )
        .bind(processed)
        .bind(total)
        .bind(id)
        .execute(&self.pool)
        .await?;
        Ok(done.rows_affected() == 1)
    }

    pub async fn mark_export_ready(&self, id: ExportId, size_bytes: i64) -> anyhow::Result<bool> {
        let now = now_ms();
        let done = sqlx::query(
            "UPDATE data_exports
             SET status = 'ready', size_bytes = ?, finished_at = ?, expires_at = ?,
                 processed = total
             WHERE id = ? AND status = 'running'",
        )
        .bind(size_bytes)
        .bind(now)
        .bind(now + EXPORT_RETENTION_MS)
        .bind(id)
        .execute(&self.pool)
        .await?;
        Ok(done.rows_affected() == 1)
    }

    pub async fn mark_export_failed(&self, id: ExportId, reason: &str) -> anyhow::Result<()> {
        sqlx::query(
            "UPDATE data_exports SET status = 'failed', error = ?, finished_at = ?
             WHERE id = ? AND status IN ('queued', 'running')",
        )
        .bind(reason)
        .bind(now_ms())
        .bind(id)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// Removes the row; the caller deletes the file.
    pub async fn delete_data_export(&self, id: ExportId) -> anyhow::Result<()> {
        sqlx::query("DELETE FROM data_exports WHERE id = ?")
            .bind(id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    /// Jobs a restart interrupted can never finish, so they are failed.
    pub async fn fail_interrupted_exports(&self) -> anyhow::Result<u64> {
        let done = sqlx::query(
            "UPDATE data_exports
             SET status = 'failed', error = 'the server restarted before this finished',
                 finished_at = ?
             WHERE status IN ('queued', 'running')",
        )
        .bind(now_ms())
        .execute(&self.pool)
        .await?;
        Ok(done.rows_affected())
    }

    /// Marks ready archives past their expiry and returns their ids, so the
    /// caller deletes the files; also drops rows nobody needs to see any more.
    pub async fn expire_data_exports(&self, now: i64) -> anyhow::Result<Vec<ExportId>> {
        let rows = sqlx::query(
            "UPDATE data_exports SET status = 'expired'
             WHERE status = 'ready' AND expires_at <= ? RETURNING id",
        )
        .bind(now)
        .fetch_all(&self.pool)
        .await?;
        sqlx::query(
            "DELETE FROM data_exports
             WHERE status IN ('expired', 'failed') AND finished_at <= ?",
        )
        .bind(now - EXPORT_ROW_KEEP_MS)
        .execute(&self.pool)
        .await?;
        Ok(rows.iter().map(|row| row.get("id")).collect())
    }

    /// Whether a row still wants the file named `id` (queued, running or ready).
    pub async fn export_file_is_wanted(&self, id: ExportId) -> anyhow::Result<bool> {
        let row = sqlx::query(
            "SELECT 1 FROM data_exports WHERE id = ? AND status IN ('queued', 'running', 'ready')",
        )
        .bind(id)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.is_some())
    }
}
