// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A module's one-shot timers: a command the host runs once at a time the
//! module chose. One row per (module, command, key), so asking again replaces
//! the pending one instead of stacking.

use super::super::Store;
use crate::ids::ChannelId;

/// A timer waiting for its time.
#[derive(Debug, Clone)]
pub struct DueTimer {
    pub module_id: String,
    pub command: String,
    pub key: String,
    pub input: String,
    pub channel_id: Option<ChannelId>,
}

/// What a module asked for, already validated.
pub struct TimerSpec<'a> {
    pub command: &'a str,
    pub key: &'a str,
    pub input: &'a str,
    pub channel_id: Option<ChannelId>,
    pub run_at: i64,
}

impl Store {
    /// Sets the timer, or `Ok(false)` when it would be a new one past `max_pending`.
    pub async fn set_module_timer(
        &self,
        module_id: &str,
        timer: &TimerSpec<'_>,
        max_pending: i64,
    ) -> anyhow::Result<bool> {
        let mut tx = self.begin_write().await?;
        let replaces = sqlx::query_scalar::<_, i64>(
            "SELECT COUNT(*) FROM module_timers WHERE module_id = ? AND command = ? AND key = ?",
        )
        .bind(module_id)
        .bind(timer.command)
        .bind(timer.key)
        .fetch_one(&mut *tx)
        .await?;
        let pending =
            sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM module_timers WHERE module_id = ?")
                .bind(module_id)
                .fetch_one(&mut *tx)
                .await?;
        if replaces == 0 && pending >= max_pending {
            return Ok(false);
        }
        sqlx::query(
            "INSERT INTO module_timers (module_id, command, key, input, channel_id, run_at) \
             VALUES (?, ?, ?, ?, ?, ?) \
             ON CONFLICT (module_id, command, key) DO UPDATE SET \
                 input = excluded.input, channel_id = excluded.channel_id, run_at = excluded.run_at",
        )
        .bind(module_id)
        .bind(timer.command)
        .bind(timer.key)
        .bind(timer.input)
        .bind(timer.channel_id)
        .bind(timer.run_at)
        .execute(&mut *tx)
        .await?;
        tx.commit().await?;
        Ok(true)
    }

    /// Cancels a pending timer; `Ok(false)` when there was none.
    pub async fn cancel_module_timer(
        &self,
        module_id: &str,
        command: &str,
        key: &str,
    ) -> anyhow::Result<bool> {
        let affected = sqlx::query(
            "DELETE FROM module_timers WHERE module_id = ? AND command = ? AND key = ?",
        )
        .bind(module_id)
        .bind(command)
        .bind(key)
        .execute(&self.pool)
        .await?
        .rows_affected();
        Ok(affected > 0)
    }

    /// Removes and returns every timer due at `now`, oldest first, at most `limit`.
    pub async fn take_due_module_timers(
        &self,
        now: i64,
        limit: i64,
    ) -> anyhow::Result<Vec<DueTimer>> {
        use sqlx::Row;
        let mut tx = self.begin_write().await?;
        let rows = sqlx::query(
            "SELECT module_id, command, key, input, channel_id FROM module_timers \
             WHERE run_at <= ? ORDER BY run_at LIMIT ?",
        )
        .bind(now)
        .bind(limit)
        .fetch_all(&mut *tx)
        .await?;
        let mut due = Vec::with_capacity(rows.len());
        for row in rows {
            let timer = DueTimer {
                module_id: row.try_get("module_id")?,
                command: row.try_get("command")?,
                key: row.try_get("key")?,
                input: row.try_get("input")?,
                channel_id: row.try_get("channel_id")?,
            };
            sqlx::query(
                "DELETE FROM module_timers WHERE module_id = ? AND command = ? AND key = ?",
            )
            .bind(&timer.module_id)
            .bind(&timer.command)
            .bind(&timer.key)
            .execute(&mut *tx)
            .await?;
            due.push(timer);
        }
        tx.commit().await?;
        Ok(due)
    }

    /// How many timers the module has waiting.
    pub async fn pending_module_timers(&self, module_id: &str) -> anyhow::Result<i64> {
        Ok(
            sqlx::query_scalar("SELECT COUNT(*) FROM module_timers WHERE module_id = ?")
                .bind(module_id)
                .fetch_one(&self.pool)
                .await?,
        )
    }
}
