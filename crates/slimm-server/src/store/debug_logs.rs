// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `debug_logs`: client logs members chose to send to the admins. The text is
//! only read for one row at a time; the list never carries it.

use super::{Store, now_ms};
use crate::ids::UserId;

/// How many logs one member keeps; the oldest go when a new one arrives.
pub const DEBUG_LOGS_PER_USER: i64 = 10;
/// How long a log is kept.
pub const DEBUG_LOG_RETENTION_MS: i64 = 30 * 24 * 60 * 60 * 1000;

/// What a member sends along with the log text.
pub struct NewDebugLog<'a> {
    pub note: &'a str,
    pub app_version: &'a str,
    pub platform: &'a str,
    pub log: &'a str,
}

/// A submitted log without its text.
#[derive(Debug, Clone)]
pub struct DebugLogSummary {
    pub id: i64,
    pub user_id: UserId,
    pub username: String,
    pub display_name: String,
    pub note: String,
    pub app_version: String,
    pub platform: String,
    pub size_bytes: i64,
    pub created_at: i64,
}

/// A submitted log with its text.
#[derive(Debug, Clone)]
pub struct DebugLogFull {
    pub summary: DebugLogSummary,
    pub log: String,
}

impl Store {
    /// Stores `new` for `user_id`, answers its id and time, and drops that member's logs beyond the newest [`DEBUG_LOGS_PER_USER`].
    pub async fn submit_debug_log(
        &self,
        user_id: UserId,
        new: &NewDebugLog<'_>,
    ) -> anyhow::Result<(i64, i64)> {
        let created_at = now_ms();
        let size = i64::try_from(new.log.len())?;
        let mut tx = self.begin_write().await?;
        let id = sqlx::query_scalar!(
            r#"INSERT INTO debug_logs (user_id, note, app_version, platform, log, size_bytes, created_at)
               VALUES (?, ?, ?, ?, ?, ?, ?) RETURNING id AS "id!: i64""#,
            user_id,
            new.note,
            new.app_version,
            new.platform,
            new.log,
            size,
            created_at
        )
        .fetch_one(&mut *tx)
        .await?;
        sqlx::query!(
            "DELETE FROM debug_logs WHERE user_id = ? AND id NOT IN (
                 SELECT id FROM debug_logs WHERE user_id = ? ORDER BY id DESC LIMIT ?
             )",
            user_id,
            user_id,
            DEBUG_LOGS_PER_USER
        )
        .execute(&mut *tx)
        .await?;
        tx.commit().await?;
        Ok((id, created_at))
    }

    /// Up to `limit` logs older than `before` (an id), newest first, without their text.
    pub async fn list_debug_logs(
        &self,
        before: Option<i64>,
        limit: i64,
    ) -> anyhow::Result<Vec<DebugLogSummary>> {
        let before = before.unwrap_or(i64::MAX);
        let rows = sqlx::query_as!(
            DebugLogSummary,
            r#"SELECT d.id AS "id!", d.user_id AS "user_id: UserId", u.username, u.display_name,
                      d.note, d.app_version, d.platform, d.size_bytes, d.created_at
               FROM debug_logs d JOIN users u ON u.id = d.user_id
               WHERE d.id < ? ORDER BY d.id DESC LIMIT ?"#,
            before,
            limit
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    pub async fn debug_log(&self, id: i64) -> anyhow::Result<Option<DebugLogFull>> {
        let row = sqlx::query!(
            r#"SELECT d.id AS "id!", d.user_id AS "user_id: UserId", u.username, u.display_name,
                      d.note, d.app_version, d.platform, d.size_bytes, d.created_at, d.log
               FROM debug_logs d JOIN users u ON u.id = d.user_id WHERE d.id = ?"#,
            id
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.map(|r| DebugLogFull {
            summary: DebugLogSummary {
                id: r.id,
                user_id: r.user_id,
                username: r.username,
                display_name: r.display_name,
                note: r.note,
                app_version: r.app_version,
                platform: r.platform,
                size_bytes: r.size_bytes,
                created_at: r.created_at,
            },
            log: r.log,
        }))
    }

    /// Answers whether a row was there to delete.
    pub async fn delete_debug_log(&self, id: i64) -> anyhow::Result<bool> {
        let done = sqlx::query!("DELETE FROM debug_logs WHERE id = ?", id)
            .execute(&self.pool)
            .await?;
        Ok(done.rows_affected() == 1)
    }

    /// Deletes logs older than [`DEBUG_LOG_RETENTION_MS`].
    pub async fn sweep_debug_logs(&self) -> anyhow::Result<u64> {
        self.sweep_debug_logs_at(now_ms()).await
    }

    pub async fn sweep_debug_logs_at(&self, now: i64) -> anyhow::Result<u64> {
        let cutoff = now - DEBUG_LOG_RETENTION_MS;
        Ok(
            sqlx::query!("DELETE FROM debug_logs WHERE created_at < ?", cutoff)
                .execute(&self.pool)
                .await?
                .rows_affected(),
        )
    }
}
