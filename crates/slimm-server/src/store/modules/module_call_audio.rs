// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The voice channels an admin lets a module hear (decision 0105).

use super::super::Store;
use crate::ids::ChannelId;

impl Store {
    /// The channels `module_id` may hear, in no particular order.
    pub async fn module_call_audio_channels(
        &self,
        module_id: &str,
    ) -> anyhow::Result<Vec<ChannelId>> {
        let rows = sqlx::query_scalar::<_, ChannelId>(
            "SELECT channel_id FROM module_call_audio_channels WHERE module_id = ?",
        )
        .bind(module_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    /// The modules armed for `channel`.
    pub async fn call_audio_modules_for_channel(
        &self,
        channel: ChannelId,
    ) -> anyhow::Result<Vec<String>> {
        let rows = sqlx::query_scalar::<_, String>(
            "SELECT module_id FROM module_call_audio_channels WHERE channel_id = ? ORDER BY module_id",
        )
        .bind(channel)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    /// Whether `module_id` is armed for `channel`.
    pub async fn call_audio_armed(
        &self,
        module_id: &str,
        channel: ChannelId,
    ) -> anyhow::Result<bool> {
        let found = sqlx::query_scalar::<_, i64>(
            "SELECT 1 FROM module_call_audio_channels WHERE module_id = ? AND channel_id = ?",
        )
        .bind(module_id)
        .bind(channel)
        .fetch_optional(&self.pool)
        .await?;
        Ok(found.is_some())
    }

    /// Replaces the module's list with `channels`, returning the ones it dropped.
    pub async fn set_module_call_audio_channels(
        &self,
        module_id: &str,
        channels: &[ChannelId],
    ) -> anyhow::Result<Vec<ChannelId>> {
        let mut tx = self.begin_write().await?;
        let before = sqlx::query_scalar::<_, ChannelId>(
            "SELECT channel_id FROM module_call_audio_channels WHERE module_id = ?",
        )
        .bind(module_id)
        .fetch_all(&mut *tx)
        .await?;
        sqlx::query("DELETE FROM module_call_audio_channels WHERE module_id = ?")
            .bind(module_id)
            .execute(&mut *tx)
            .await?;
        for channel in channels {
            sqlx::query(
                "INSERT OR IGNORE INTO module_call_audio_channels (module_id, channel_id) VALUES (?, ?)",
            )
            .bind(module_id)
            .bind(*channel)
            .execute(&mut *tx)
            .await?;
        }
        tx.commit().await?;
        Ok(before
            .into_iter()
            .filter(|old| !channels.contains(old))
            .collect())
    }
}
