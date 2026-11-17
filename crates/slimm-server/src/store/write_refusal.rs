// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The facts `http::write_refusal` reads to say why a write was refused.

use super::Store;
use super::dms::DM_CHANNEL_KIND;
use crate::ids::{ChannelId, UserId};

impl Store {
    /// Whether `user_id` posted in the group DM `channel_id` and is no longer on
    /// its roster: the one case where naming the group cannot tell them anything new.
    pub async fn is_former_group_dm_poster(
        &self,
        user_id: UserId,
        channel_id: ChannelId,
    ) -> anyhow::Result<bool> {
        let found: Option<i64> = sqlx::query_scalar(
            "SELECT 1 FROM channels c \
             WHERE c.id = ? AND c.kind = ? AND c.deleted_at IS NULL \
               AND NOT EXISTS (SELECT 1 FROM dm_channels d WHERE d.channel_id = c.id) \
               AND NOT EXISTS (SELECT 1 FROM group_dm_members g \
                               WHERE g.channel_id = c.id AND g.user_id = ?) \
               AND EXISTS (SELECT 1 FROM messages m \
                           WHERE m.channel_id = c.id AND m.author_id = ?)",
        )
        .bind(channel_id)
        .bind(DM_CHANNEL_KIND)
        .bind(user_id)
        .bind(user_id)
        .fetch_optional(&self.pool)
        .await?;
        Ok(found.is_some())
    }
}
