// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A channel's own retention window, overriding the Space's
//! (`message_retention.rs`). No row follows the Space; `0` keeps the channel
//! forever. A thread follows its parent channel, so the sweep resolves every
//! message to the channel that owns its window before comparing ages.
use super::{Store, now_ms};
use crate::ids::ChannelId;

const DAY_MS: i64 = 24 * 60 * 60 * 1000;

impl Store {
    /// This channel's own override, or `None` when it follows the Space.
    pub async fn channel_retention_days(
        &self,
        channel_id: ChannelId,
    ) -> anyhow::Result<Option<i64>> {
        let days = sqlx::query_scalar!(
            r#"SELECT retention_days AS "d!: i64" FROM channel_retention WHERE channel_id = ?"#,
            channel_id
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(days)
    }

    /// Sets the override, or clears it with `None` so the channel follows the
    /// Space again. Callers validate the range first; the column's `CHECK` is
    /// the backstop.
    pub async fn set_channel_retention_days(
        &self,
        channel_id: ChannelId,
        days: Option<i64>,
    ) -> anyhow::Result<()> {
        match days {
            Some(days) => {
                let now = now_ms();
                sqlx::query!(
                    "INSERT INTO channel_retention (channel_id, retention_days, updated_at)
                     VALUES (?, ?, ?)
                     ON CONFLICT(channel_id) DO UPDATE
                     SET retention_days = excluded.retention_days, updated_at = excluded.updated_at",
                    channel_id,
                    days,
                    now
                )
                .execute(&self.pool)
                .await?;
            }
            None => {
                sqlx::query!(
                    "DELETE FROM channel_retention WHERE channel_id = ?",
                    channel_id
                )
                .execute(&self.pool)
                .await?;
            }
        }
        Ok(())
    }

    /// How many live messages in this channel and its threads a window of
    /// `days` would prune now. `0` prunes nothing.
    pub async fn count_messages_past_channel_retention(
        &self,
        channel_id: ChannelId,
        days: i64,
    ) -> anyhow::Result<i64> {
        if days <= 0 {
            return Ok(0);
        }
        let cutoff = now_ms() - days * DAY_MS;
        let count = sqlx::query_scalar!(
            r#"SELECT COUNT(*) AS "n!: i64" FROM messages m
               JOIN channels c ON c.id = m.channel_id
               LEFT JOIN messages pm ON pm.id = c.parent_message_id
               WHERE m.deleted_at IS NULL AND m.created_at < ?
                 AND COALESCE(pm.channel_id, c.id) = ?"#,
            cutoff,
            channel_id
        )
        .fetch_one(&self.pool)
        .await?;
        Ok(count)
    }
}
