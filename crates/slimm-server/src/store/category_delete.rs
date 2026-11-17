// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Deleting a category moves what it holds up one level, keeping every
//! overwrite so nobody's view changes (decision 0120).

use super::categories::fetch_live_category;
use super::{Store, now_ms};
use crate::ids::{ChannelCategoryId, ChannelId};

impl Store {
    /// Soft-deletes a category after moving its contents up one level, in one
    /// transaction. False when it was already gone, so a retry is not an error.
    pub async fn delete_category(&self, id: ChannelCategoryId) -> anyhow::Result<bool> {
        let now = now_ms();
        let mut tx = self.begin_write().await?;
        let Some(category) = fetch_live_category(&mut *tx, id).await? else {
            tx.commit().await?;
            return Ok(false);
        };
        match category.parent_id {
            Some(parent) => move_channels_into_parent(&mut tx, id, parent).await?,
            None => {
                sqlx::query!(
                    "UPDATE channels SET category_id = NULL, permissions_synced = 0
                     WHERE category_id = ?",
                    id
                )
                .execute(&mut *tx)
                .await?;
                promote_sub_categories(&mut tx, id).await?;
            }
        }
        // Migration 0193 refuses this while a live sub-category remains, so it runs last.
        sqlx::query!(
            "UPDATE channel_categories SET deleted_at = ? WHERE id = ?",
            now,
            id
        )
        .execute(&mut *tx)
        .await?;
        tx.commit().await?;
        Ok(true)
    }
}

/// Files `from`'s channels after `parent`'s own, in their existing order.
async fn move_channels_into_parent(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    from: ChannelCategoryId,
    parent: ChannelCategoryId,
) -> Result<(), sqlx::Error> {
    let first = sqlx::query_scalar!(
        r#"SELECT COALESCE(MAX(position), -1) + 1 AS "next!: i64" FROM channels
           WHERE category_id = ? AND deleted_at IS NULL"#,
        parent
    )
    .fetch_one(&mut **tx)
    .await?;
    let moving = sqlx::query_scalar!(
        r#"SELECT id AS "id!: ChannelId" FROM channels
           WHERE category_id = ? AND deleted_at IS NULL
             AND room_owner_id IS NULL AND room_lobby_id IS NULL
           ORDER BY position, created_at, id"#,
        from
    )
    .fetch_all(&mut **tx)
    .await?;
    for (offset, channel) in (0_i64..).zip(moving) {
        let position = first + offset;
        sqlx::query!(
            "UPDATE channels SET category_id = ?, position = ?, permissions_synced = 0
             WHERE id = ?",
            parent,
            position,
            channel
        )
        .execute(&mut **tx)
        .await?;
    }
    // A temporary room sits at its lobby's position, which just changed.
    sqlx::query!(
        "UPDATE channels SET category_id = ?, permissions_synced = 0,
             position = COALESCE(
                 (SELECT l.position FROM channels l WHERE l.id = channels.room_lobby_id),
                 position)
         WHERE category_id = ?",
        parent,
        from
    )
    .execute(&mut **tx)
    .await?;
    Ok(())
}

/// Moves `parent`'s live sub-categories to the top level in the slot it holds,
/// renumbering the top level around them.
async fn promote_sub_categories(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    parent: ChannelCategoryId,
) -> Result<(), sqlx::Error> {
    let children = sqlx::query_scalar!(
        r#"SELECT id AS "id!: ChannelCategoryId" FROM channel_categories
           WHERE parent_id = ? AND deleted_at IS NULL
           ORDER BY position, created_at, id"#,
        parent
    )
    .fetch_all(&mut **tx)
    .await?;
    if children.is_empty() {
        return Ok(());
    }
    let top_level = sqlx::query_scalar!(
        r#"SELECT id AS "id!: ChannelCategoryId" FROM channel_categories
           WHERE parent_id IS NULL AND deleted_at IS NULL
           ORDER BY position, created_at, id"#
    )
    .fetch_all(&mut **tx)
    .await?;
    sqlx::query!(
        "UPDATE channel_categories SET parent_id = NULL, permissions_synced = 0
         WHERE parent_id = ? AND deleted_at IS NULL",
        parent
    )
    .execute(&mut **tx)
    .await?;
    let order = top_level.into_iter().flat_map(|id| {
        if id == parent {
            children.clone()
        } else {
            vec![id]
        }
    });
    for (position, id) in (0_i64..).zip(order) {
        sqlx::query!(
            "UPDATE channel_categories SET position = ? WHERE id = ?",
            position,
            id
        )
        .execute(&mut **tx)
        .await?;
    }
    Ok(())
}
