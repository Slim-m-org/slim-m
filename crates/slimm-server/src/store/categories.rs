// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Channel category persistence: create, rename, reposition, and soft-delete.
//!
//! A category is organisational only - it groups and orders channels of any
//! kind, and grants and denies nothing. See
//! docs/decisions/0006-channel-categories.md and docs/IMPLIED-GAPS.md.

use sqlx::SqliteExecutor;

use super::{ChannelCategory, Store, now_ms};
use crate::ids::ChannelCategoryId;

/// The outcome of a create, which is idempotent by client-supplied id and so
/// may be a retry; see [`Store::create_category_with_id`].
#[derive(Debug, Clone)]
pub struct CreatedCategory {
    pub category: ChannelCategory,
    /// False when this id already named a category, so the call was a retry
    /// of a create that already succeeded. The caller publishes
    /// `CategoryChanged` only when this is true, or a retry would wake every
    /// connected client a second time for a category they already know
    /// about.
    pub fresh: bool,
}

impl Store {
    /// Lists the deployment's live categories, in display order.
    pub async fn list_categories(&self) -> anyhow::Result<Vec<ChannelCategory>> {
        let rows = sqlx::query!(
            r#"SELECT id AS "id!: ChannelCategoryId", name AS "name!",
                      position AS "position!: i64", created_at AS "created_at!"
               FROM channel_categories
               WHERE deleted_at IS NULL
               ORDER BY position, created_at"#
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .into_iter()
            .map(|r| ChannelCategory {
                id: r.id,
                name: r.name,
                position: r.position,
                created_at: r.created_at,
            })
            .collect())
    }

    /// Creates a category, appended after every live one - the same
    /// "read the live maximum inside this transaction" shape
    /// [`super::channel_create::Store::create_channel_with_id`] uses for a
    /// channel's own position, so two concurrent creates cannot both claim
    /// the last slot.
    ///
    /// Idempotent by `id`: a retry with the same id returns the row already
    /// stored under it rather than inserting again, the same contract
    /// [`super::messages::Store::send_message`] gives a message send.
    /// [`Store::create_category`] is the convenience form for a caller with
    /// no client-supplied id of its own; it mints one and always sees
    /// [`CreatedCategory::fresh`] true, since a freshly generated UUIDv7 id
    /// cannot already be in use.
    ///
    /// Unlike [`super::channel_create::Store::create_channel_with_id`] and
    /// [`super::permissions::Store::create_role_with_id`], the id probe
    /// below is never scoped to a sub-type: `channel_categories` is written
    /// by nothing but this function and migration 0031's own seed, so every
    /// row this probe can find is a POST /categories-creatable category and
    /// a bare id match is always a genuine retry.
    pub async fn create_category_with_id(
        &self,
        id: ChannelCategoryId,
        name: &str,
    ) -> anyhow::Result<CreatedCategory> {
        let now = now_ms();
        let mut tx = self.begin_write().await?;

        // Probes including a deleted row; see `create_channel_with_id`'s doc.
        if let Some(existing) = fetch_category_by_id(&mut *tx, id).await? {
            tx.commit().await?;
            return Ok(CreatedCategory {
                category: existing,
                fresh: false,
            });
        }

        let position = sqlx::query_scalar!(
            r#"SELECT COALESCE(MAX(position), -1) + 1 AS "next!: i64" FROM channel_categories
               WHERE deleted_at IS NULL"#
        )
        .fetch_one(&mut *tx)
        .await?;
        sqlx::query!(
            "INSERT INTO channel_categories (id, name, position, created_at) VALUES (?, ?, ?, ?)",
            id,
            name,
            position,
            now
        )
        .execute(&mut *tx)
        .await?;
        tx.commit().await?;
        Ok(CreatedCategory {
            category: ChannelCategory {
                id,
                name: name.to_owned(),
                position,
                created_at: now,
            },
            fresh: true,
        })
    }

    /// Creates a category with a server-minted id; see
    /// [`Store::create_category_with_id`] for the idempotent form a caller
    /// with a client-supplied id wants instead.
    pub async fn create_category(&self, name: &str) -> anyhow::Result<ChannelCategory> {
        Ok(self
            .create_category_with_id(ChannelCategoryId::generate(), name)
            .await?
            .category)
    }

    /// Renames and/or repositions a category. `None` for either leaves that
    /// field untouched, the same "at least one, absent means unchanged"
    /// convention [`super::channels::Store::update_channel`] follows.
    /// Returns `None` if the category does not exist or was deleted.
    pub async fn update_category(
        &self,
        id: ChannelCategoryId,
        name: Option<&str>,
        position: Option<i64>,
    ) -> anyhow::Result<Option<ChannelCategory>> {
        let affected = match (name, position) {
            (Some(name), Some(position)) => sqlx::query!(
                "UPDATE channel_categories SET name = ?, position = ? \
                 WHERE id = ? AND deleted_at IS NULL",
                name,
                position,
                id
            )
            .execute(&self.pool)
            .await?
            .rows_affected(),
            (Some(name), None) => sqlx::query!(
                "UPDATE channel_categories SET name = ? WHERE id = ? AND deleted_at IS NULL",
                name,
                id
            )
            .execute(&self.pool)
            .await?
            .rows_affected(),
            (None, Some(position)) => sqlx::query!(
                "UPDATE channel_categories SET position = ? WHERE id = ? AND deleted_at IS NULL",
                position,
                id
            )
            .execute(&self.pool)
            .await?
            .rows_affected(),
            (None, None) => {
                let exists = sqlx::query_scalar!(
                    r#"SELECT 1 AS "one!: i64" FROM channel_categories
                       WHERE id = ? AND deleted_at IS NULL"#,
                    id
                )
                .fetch_optional(&self.pool)
                .await?;
                u64::from(exists.is_some())
            }
        };
        if affected == 0 {
            return Ok(None);
        }
        let row = sqlx::query!(
            r#"SELECT id AS "id!: ChannelCategoryId", name AS "name!",
                      position AS "position!: i64", created_at AS "created_at!"
               FROM channel_categories WHERE id = ? AND deleted_at IS NULL"#,
            id
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.map(|r| ChannelCategory {
            id: r.id,
            name: r.name,
            position: r.position,
            created_at: r.created_at,
        }))
    }

    /// Soft-deletes a category. Its channels are never deleted with it - they
    /// fall back to uncategorised in the same transaction, so a channel is
    /// never orphaned even for the instant between the two statements.
    /// Returns whether this call performed the delete, so a retry against an
    /// already-deleted category is idempotent rather than an error, the same
    /// convention [`super::channels::Store::delete_channel`] follows.
    pub async fn delete_category(&self, id: ChannelCategoryId) -> anyhow::Result<bool> {
        let now = now_ms();
        let mut tx = self.begin_write().await?;
        let affected = sqlx::query!(
            "UPDATE channel_categories SET deleted_at = ? WHERE id = ? AND deleted_at IS NULL",
            now,
            id
        )
        .execute(&mut *tx)
        .await?
        .rows_affected();
        if affected > 0 {
            sqlx::query!(
                "UPDATE channels SET category_id = NULL, permissions_synced = 0 WHERE category_id = ?",
                id
            )
            .execute(&mut *tx)
            .await?;
        }
        tx.commit().await?;
        Ok(affected > 0)
    }
}

/// Fetches a category by id, live or deleted, over any executor - an open
/// transaction for the id probe inside [`Store::create_category_with_id`].
async fn fetch_category_by_id<'e, E>(
    executor: E,
    id: ChannelCategoryId,
) -> anyhow::Result<Option<ChannelCategory>>
where
    E: SqliteExecutor<'e>,
{
    let row = sqlx::query!(
        r#"SELECT id AS "id!: ChannelCategoryId", name AS "name!",
                  position AS "position!: i64", created_at AS "created_at!"
           FROM channel_categories WHERE id = ?"#,
        id
    )
    .fetch_optional(executor)
    .await?;
    Ok(row.map(|r| ChannelCategory {
        id: r.id,
        name: r.name,
        position: r.position,
        created_at: r.created_at,
    }))
}
