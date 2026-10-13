// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Category permissions (decision 0064): a category's own overwrites, and the
//! copy a synced channel carries of them. The evaluator never reads these
//! rows; a sync only changes which `channel_overwrites` rows a channel holds.

use anyhow::Context;
use uuid::Uuid;

use super::Store;
use super::overwrites_batch::OverwriteBatchEntry;
use super::permissions::ChannelOverwrite;
use crate::ids::{ChannelCategoryId, ChannelId};
use crate::permissions::Permissions;

/// Replaces [channel]'s overwrites with [category]'s and marks it synced.
pub(super) async fn copy_category_overwrites(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    channel: ChannelId,
    category: ChannelCategoryId,
) -> Result<(), sqlx::Error> {
    sqlx::query!(
        "DELETE FROM channel_overwrites WHERE channel_id = ?",
        channel
    )
    .execute(&mut **tx)
    .await?;
    sqlx::query!(
        "INSERT INTO channel_overwrites (channel_id, target_type, target_id, allow, deny)
         SELECT ?, target_type, target_id, allow, deny
         FROM category_overwrites WHERE category_id = ?",
        channel,
        category
    )
    .execute(&mut **tx)
    .await?;
    sqlx::query!(
        "UPDATE channels SET permissions_synced = 1 WHERE id = ?",
        channel
    )
    .execute(&mut **tx)
    .await?;
    Ok(())
}

/// Marks [channel] as holding its own overwrites, after an edit of its own.
pub(super) async fn mark_unsynced<'e, E>(executor: E, channel: ChannelId) -> anyhow::Result<()>
where
    E: sqlx::SqliteExecutor<'e>,
{
    sqlx::query!(
        "UPDATE channels SET permissions_synced = 0 WHERE id = ?",
        channel
    )
    .execute(executor)
    .await
    .context("mark channel unsynced")?;
    Ok(())
}

impl Store {
    pub async fn category_overwrites(
        &self,
        category: ChannelCategoryId,
    ) -> anyhow::Result<Vec<ChannelOverwrite>> {
        let rows = sqlx::query!(
            r#"SELECT target_type AS "target_type!",
                      target_id AS "target_id!: Uuid",
                      allow AS "allow!: Permissions",
                      deny AS "deny!: Permissions"
               FROM category_overwrites
               WHERE category_id = ?
               ORDER BY target_type, target_id"#,
            category
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .into_iter()
            .map(|r| ChannelOverwrite {
                target_type: r.target_type,
                target_id: r.target_id,
                allow: r.allow,
                deny: r.deny,
            })
            .collect())
    }

    /// One category overwrite's current pair, for the escalation check.
    pub async fn category_overwrite_for(
        &self,
        category: ChannelCategoryId,
        target_type: &str,
        target_id: Uuid,
    ) -> anyhow::Result<Option<(Permissions, Permissions)>> {
        let row = sqlx::query!(
            r#"SELECT allow AS "allow!: Permissions", deny AS "deny!: Permissions"
               FROM category_overwrites
               WHERE category_id = ? AND target_type = ? AND target_id = ?"#,
            category,
            target_type,
            target_id
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.map(|r| (r.allow, r.deny)))
    }

    /// The live channels in [category] that are synced to it.
    pub async fn synced_channels_in(
        &self,
        category: ChannelCategoryId,
    ) -> anyhow::Result<Vec<ChannelId>> {
        Ok(sqlx::query_scalar!(
            r#"SELECT id AS "id!: ChannelId" FROM channels
               WHERE category_id = ? AND permissions_synced = 1 AND deleted_at IS NULL"#,
            category
        )
        .fetch_all(&self.pool)
        .await?)
    }

    /// Applies [entries] to [category] (an all-zero pair removes that target)
    /// and copies the result into every synced channel, in one transaction.
    pub async fn set_category_overwrites(
        &self,
        category: ChannelCategoryId,
        entries: &[OverwriteBatchEntry],
    ) -> anyhow::Result<()> {
        let mut tx = self.begin_write().await?;
        for entry in entries {
            if entry.allow == Permissions::NONE && entry.deny == Permissions::NONE {
                sqlx::query!(
                    "DELETE FROM category_overwrites
                     WHERE category_id = ? AND target_type = ? AND target_id = ?",
                    category,
                    entry.target_type,
                    entry.target_id
                )
                .execute(&mut *tx)
                .await?;
                continue;
            }
            let (allow, deny) = (entry.allow.bits(), entry.deny.bits());
            sqlx::query!(
                "INSERT INTO category_overwrites (category_id, target_type, target_id, allow, deny)
                 VALUES (?, ?, ?, ?, ?)
                 ON CONFLICT(category_id, target_type, target_id)
                 DO UPDATE SET allow = excluded.allow, deny = excluded.deny",
                category,
                entry.target_type,
                entry.target_id,
                allow,
                deny
            )
            .execute(&mut *tx)
            .await?;
        }
        let synced = sqlx::query_scalar!(
            r#"SELECT id AS "id!: ChannelId" FROM channels
               WHERE category_id = ? AND permissions_synced = 1 AND deleted_at IS NULL"#,
            category
        )
        .fetch_all(&mut *tx)
        .await?;
        for channel in synced {
            copy_category_overwrites(&mut tx, channel, category).await?;
        }
        tx.commit().await?;
        Ok(())
    }

    /// Whether [channel] follows its category; None for a missing channel.
    pub async fn channel_permissions_synced(
        &self,
        channel: ChannelId,
    ) -> anyhow::Result<Option<bool>> {
        Ok(sqlx::query_scalar!(
            r#"SELECT permissions_synced AS "synced!: bool" FROM channels WHERE id = ?"#,
            channel
        )
        .fetch_optional(&self.pool)
        .await?)
    }

    /// Syncs [channel] to its category. False when it has none.
    pub async fn sync_channel_permissions(&self, channel: ChannelId) -> anyhow::Result<bool> {
        let mut tx = self.begin_write().await?;
        let category = sqlx::query_scalar!(
            r#"SELECT category_id AS "category_id: ChannelCategoryId"
               FROM channels WHERE id = ? AND deleted_at IS NULL"#,
            channel
        )
        .fetch_optional(&mut *tx)
        .await?
        .flatten();
        let Some(category) = category else {
            return Ok(false);
        };
        copy_category_overwrites(&mut tx, channel, category).await?;
        tx.commit().await?;
        Ok(true)
    }
}
