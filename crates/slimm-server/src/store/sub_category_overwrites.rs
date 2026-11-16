// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Decision 0064's copy one level up (decision 0120): a synced sub-category
//! carries a copy of its parent's overwrites, and its synced channels of those.

use super::Store;
use super::category_overwrites::copy_category_overwrites;
use crate::ids::{ChannelCategoryId, ChannelId};

/// Replaces `child`'s category overwrites with `parent`'s, leaving its synced flag alone.
pub(super) async fn copy_parent_overwrites(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    child: ChannelCategoryId,
    parent: ChannelCategoryId,
) -> Result<(), sqlx::Error> {
    sqlx::query!(
        "DELETE FROM category_overwrites WHERE category_id = ?",
        child
    )
    .execute(&mut **tx)
    .await?;
    sqlx::query!(
        "INSERT INTO category_overwrites (category_id, target_type, target_id, allow, deny)
         SELECT ?, target_type, target_id, allow, deny
         FROM category_overwrites WHERE category_id = ?",
        child,
        parent
    )
    .execute(&mut **tx)
    .await?;
    Ok(())
}

/// Copies `parent`'s overwrites into each live sub-category synced to it; an unsynced one keeps its own.
pub(super) async fn copy_into_synced_sub_categories(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    parent: ChannelCategoryId,
) -> Result<(), sqlx::Error> {
    let synced = sqlx::query_scalar!(
        r#"SELECT id AS "id!: ChannelCategoryId" FROM channel_categories
           WHERE parent_id = ? AND permissions_synced = 1 AND deleted_at IS NULL"#,
        parent
    )
    .fetch_all(&mut **tx)
    .await?;
    for child in synced {
        copy_parent_overwrites(tx, child, parent).await?;
    }
    Ok(())
}

/// Every live synced channel following `category`, directly or through a synced sub-category, with
/// its own category (a room follows its lobby instead); a save's snapshot and write share it.
pub(super) async fn synced_channels_beneath<'e, E>(
    executor: E,
    category: ChannelCategoryId,
) -> Result<Vec<(ChannelId, ChannelCategoryId)>, sqlx::Error>
where
    E: sqlx::SqliteExecutor<'e>,
{
    let rows = sqlx::query!(
        r#"SELECT ch.id AS "id!: ChannelId", ch.category_id AS "home!: ChannelCategoryId"
           FROM channels ch
           WHERE ch.deleted_at IS NULL AND ch.permissions_synced = 1
             AND ch.room_lobby_id IS NULL
             AND (ch.category_id = ?
                  OR ch.category_id IN (
                      SELECT s.id FROM channel_categories s
                      WHERE s.parent_id = ? AND s.permissions_synced = 1
                        AND s.deleted_at IS NULL))
           ORDER BY ch.id"#,
        category,
        category
    )
    .fetch_all(executor)
    .await?;
    Ok(rows.into_iter().map(|r| (r.id, r.home)).collect())
}

impl Store {
    /// The channels a save of `category`'s overwrites will copy into; see
    /// [`synced_channels_beneath`].
    pub async fn synced_channels_beneath(
        &self,
        category: ChannelCategoryId,
    ) -> anyhow::Result<Vec<ChannelId>> {
        Ok(synced_channels_beneath(&self.pool, category)
            .await?
            .into_iter()
            .map(|(channel, _)| channel)
            .collect())
    }

    /// Whether a live category follows its parent: `Some(None)` for a top-level
    /// one, which never does, and `None` when there is no such category.
    pub async fn category_sync_state(
        &self,
        category: ChannelCategoryId,
    ) -> anyhow::Result<Option<Option<bool>>> {
        let row = sqlx::query!(
            r#"SELECT parent_id IS NOT NULL AS "nested!: bool",
                      permissions_synced AS "synced!: bool"
               FROM channel_categories WHERE id = ? AND deleted_at IS NULL"#,
            category
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.map(|r| r.nested.then_some(r.synced)))
    }

    /// Makes a sub-category follow its parent again, copying on into its synced
    /// channels. False when it is not a live sub-category.
    pub async fn sync_category_permissions(
        &self,
        category: ChannelCategoryId,
    ) -> anyhow::Result<bool> {
        let mut tx = self.begin_write().await?;
        let parent = sqlx::query_scalar!(
            r#"SELECT parent_id AS "parent_id: ChannelCategoryId"
               FROM channel_categories WHERE id = ? AND deleted_at IS NULL"#,
            category
        )
        .fetch_optional(&mut *tx)
        .await?
        .flatten();
        let Some(parent) = parent else {
            return Ok(false);
        };
        copy_parent_overwrites(&mut tx, category, parent).await?;
        sqlx::query!(
            "UPDATE channel_categories SET permissions_synced = 1 WHERE id = ?",
            category
        )
        .execute(&mut *tx)
        .await?;
        for (channel, home) in synced_channels_beneath(&mut *tx, category).await? {
            copy_category_overwrites(&mut tx, channel, home).await?;
        }
        tx.commit().await?;
        Ok(true)
    }
}
