// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Shared scenes that ask the host to redraw them: when the next redraw is
//! due, and when the chain stops unless a person presses something.

use super::Store;
use crate::ids::MessageId;

impl Store {
    /// Schedules the next redraw of a message's scene. `until_at` is kept when
    /// a chain is already running and `extend` is false, so only a person's
    /// press renews the window.
    pub async fn schedule_scene_refresh(
        &self,
        message_id: MessageId,
        (due_at, until_at): (i64, i64),
        extend: bool,
    ) -> anyhow::Result<()> {
        let conflict = if extend {
            "until_at = excluded.until_at"
        } else {
            "until_at = scene_refreshes.until_at"
        };
        sqlx::query(&format!(
            "INSERT INTO scene_refreshes (message_id, due_at, until_at) VALUES (?, ?, ?) \
             ON CONFLICT (message_id) DO UPDATE SET due_at = excluded.due_at, {conflict}"
        ))
        .bind(message_id)
        .bind(due_at)
        .bind(until_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn clear_scene_refresh(&self, message_id: MessageId) -> anyhow::Result<()> {
        sqlx::query("DELETE FROM scene_refreshes WHERE message_id = ?")
            .bind(message_id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    /// Messages whose redraw is due at `now`, oldest first, with when each chain ends.
    pub async fn due_scene_refreshes(
        &self,
        now: i64,
        limit: i64,
    ) -> anyhow::Result<Vec<(MessageId, i64)>> {
        use sqlx::Row;
        let rows = sqlx::query(
            "SELECT message_id, until_at FROM scene_refreshes WHERE due_at <= ? \
             ORDER BY due_at LIMIT ?",
        )
        .bind(now)
        .bind(limit)
        .fetch_all(&self.pool)
        .await?;
        rows.into_iter()
            .map(|row| Ok((row.try_get("message_id")?, row.try_get("until_at")?)))
            .collect()
    }
}
