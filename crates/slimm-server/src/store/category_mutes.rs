// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Persistence for one account's mute of a whole category (migration 0199).
//!
//! Push fan-out resolves it in [`Store::channel_notification_choices`], below a
//! channel's own override and above its default, so nothing is copied per channel.

use super::{Store, now_ms};
use crate::ids::{ChannelCategoryId, UserId};

impl Store {
    /// Mutes `category_id` for `user_id`. True when it was not muted before.
    pub async fn mute_category(
        &self,
        user_id: UserId,
        category_id: ChannelCategoryId,
    ) -> anyhow::Result<bool> {
        let now = now_ms();
        let inserted = sqlx::query!(
            "INSERT INTO category_mutes (user_id, category_id, created_at)
             VALUES (?, ?, ?)
             ON CONFLICT (user_id, category_id) DO NOTHING",
            user_id,
            category_id,
            now,
        )
        .execute(&self.pool)
        .await?
        .rows_affected();
        Ok(inserted > 0)
    }

    /// Unmutes `category_id` for `user_id`. True when it was muted before.
    pub async fn unmute_category(
        &self,
        user_id: UserId,
        category_id: ChannelCategoryId,
    ) -> anyhow::Result<bool> {
        let removed = sqlx::query!(
            "DELETE FROM category_mutes WHERE user_id = ? AND category_id = ?",
            user_id,
            category_id,
        )
        .execute(&self.pool)
        .await?
        .rows_affected();
        Ok(removed > 0)
    }

    /// Every live category `user_id` has muted; a deleted one keeps its row but is left out.
    pub async fn list_category_mutes(
        &self,
        user_id: UserId,
    ) -> anyhow::Result<Vec<ChannelCategoryId>> {
        Ok(sqlx::query_scalar!(
            r#"SELECT m.category_id AS "category_id!: ChannelCategoryId"
               FROM category_mutes m
               JOIN channel_categories c ON c.id = m.category_id AND c.deleted_at IS NULL
               WHERE m.user_id = ?
               ORDER BY m.created_at, m.category_id"#,
            user_id,
        )
        .fetch_all(&self.pool)
        .await?)
    }
}
