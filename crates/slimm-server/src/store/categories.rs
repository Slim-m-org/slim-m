// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Channel category persistence (decisions 0006 and 0120): categories nest two levels at most,
//! refused here inside the write transaction, with migration 0193's triggers as the backstop.

use sqlx::SqliteExecutor;

use super::sub_category_overwrites::copy_parent_overwrites;
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

/// Why a category create or update was refused.
#[derive(Debug)]
pub enum CategoryWriteError {
    /// The category does not exist or was deleted.
    NotFound,
    /// The named parent is not a live category.
    UnknownParent,
    /// A category was named as its own parent.
    SelfParent,
    /// The named parent is itself a sub-category, which would be a third level.
    ParentIsNested,
    /// The category still holds sub-categories, so it cannot go under another.
    HasChildren,
    /// A create named the id of a category since deleted, whose row is not handed back.
    Deleted,
    Internal(anyhow::Error),
}

impl From<sqlx::Error> for CategoryWriteError {
    fn from(err: sqlx::Error) -> Self {
        Self::Internal(err.into())
    }
}

impl From<anyhow::Error> for CategoryWriteError {
    fn from(err: anyhow::Error) -> Self {
        Self::Internal(err)
    }
}

/// What a PATCH changes; `None` leaves that part alone.
#[derive(Debug, Clone, Copy, Default)]
pub struct CategoryUpdate<'a> {
    pub name: Option<&'a str>,
    /// The place among its siblings, new ones when `parent` moves it.
    pub position: Option<i64>,
    /// `Some(None)` moves it to the top level, `Some(Some(p))` files it under `p`.
    pub parent: Option<Option<ChannelCategoryId>>,
}

impl Store {
    /// The live categories in tree order: each top-level one by position, then its sub-categories.
    pub async fn list_categories(&self) -> anyhow::Result<Vec<ChannelCategory>> {
        let rows = sqlx::query!(
            r#"SELECT c.id AS "id!: ChannelCategoryId", c.name AS "name!",
                      c.position AS "position!: i64", c.created_at AS "created_at!",
                      c.parent_id AS "parent_id: ChannelCategoryId"
               FROM channel_categories c
               LEFT JOIN channel_categories p ON p.id = c.parent_id
               WHERE c.deleted_at IS NULL
               ORDER BY COALESCE(p.position, c.position), COALESCE(p.created_at, c.created_at),
                        COALESCE(p.id, c.id), c.parent_id IS NOT NULL,
                        c.position, c.created_at, c.id"#
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
                parent_id: r.parent_id,
            })
            .collect())
    }

    /// One live category, or `None` when it does not exist or was deleted.
    pub async fn category(&self, id: ChannelCategoryId) -> anyhow::Result<Option<ChannelCategory>> {
        fetch_live_category(&self.pool, id).await
    }

    /// Creates a category after its live siblings; a sub-category starts synced with a copy of its
    /// parent's overwrites. Idempotent by `id`: a retry answers the stored row, whatever `parent` says.
    pub async fn create_category_with_id(
        &self,
        id: ChannelCategoryId,
        name: &str,
        parent: Option<ChannelCategoryId>,
    ) -> Result<CreatedCategory, CategoryWriteError> {
        let now = now_ms();
        let mut tx = self.begin_write().await?;

        // Probes including a deleted row; see `create_channel_with_id`'s doc.
        if let Some((existing, live)) = fetch_category_by_id(&mut *tx, id).await? {
            tx.commit().await?;
            if !live {
                return Err(CategoryWriteError::Deleted);
            }
            return Ok(CreatedCategory {
                category: existing,
                fresh: false,
            });
        }
        if let Some(parent) = parent {
            check_parent(&mut tx, id, parent).await?;
        }

        let position = next_sibling_position(&mut tx, parent, None).await?;
        let synced = parent.is_some();
        sqlx::query!(
            "INSERT INTO channel_categories
                 (id, name, position, created_at, parent_id, permissions_synced)
             VALUES (?, ?, ?, ?, ?, ?)",
            id,
            name,
            position,
            now,
            parent,
            synced
        )
        .execute(&mut *tx)
        .await?;
        if let Some(parent) = parent {
            copy_parent_overwrites(&mut tx, id, parent).await?;
        }
        tx.commit().await?;
        Ok(CreatedCategory {
            category: ChannelCategory {
                id,
                name: name.to_owned(),
                position,
                created_at: now,
                parent_id: parent,
            },
            fresh: true,
        })
    }

    /// Creates a top-level category with a server-minted id; see
    /// [`Store::create_category_with_id`] for the idempotent form.
    pub async fn create_category(&self, name: &str) -> anyhow::Result<ChannelCategory> {
        match self
            .create_category_with_id(ChannelCategoryId::generate(), name, None)
            .await
        {
            Ok(created) => Ok(created.category),
            Err(CategoryWriteError::Internal(e)) => Err(e),
            Err(other) => Err(anyhow::anyhow!("top-level create refused: {other:?}")),
        }
    }

    /// Renames, repositions and/or re-parents a category. A move appends it after its new siblings
    /// unless `position` says where, and keeps its overwrites but stops following any parent's.
    pub async fn update_category(
        &self,
        id: ChannelCategoryId,
        update: CategoryUpdate<'_>,
    ) -> Result<ChannelCategory, CategoryWriteError> {
        let mut tx = self.begin_write().await?;
        let current = fetch_live_category(&mut *tx, id)
            .await?
            .ok_or(CategoryWriteError::NotFound)?;
        let moved_to = update.parent.filter(|parent| *parent != current.parent_id);
        if let Some(Some(parent)) = moved_to {
            check_parent(&mut tx, id, parent).await?;
        }
        let parent = moved_to.unwrap_or(current.parent_id);
        let position = match (update.position, moved_to) {
            (Some(position), _) => position,
            (None, Some(_)) => next_sibling_position(&mut tx, parent, Some(id)).await?,
            (None, None) => current.position,
        };
        let name = update.name.unwrap_or(&current.name).to_owned();

        sqlx::query!(
            "UPDATE channel_categories SET name = ?, position = ? WHERE id = ?",
            name,
            position,
            id
        )
        .execute(&mut *tx)
        .await?;
        if moved_to.is_some() {
            sqlx::query!(
                "UPDATE channel_categories SET parent_id = ?, permissions_synced = 0 WHERE id = ?",
                parent,
                id
            )
            .execute(&mut *tx)
            .await?;
        }
        tx.commit().await?;
        Ok(ChannelCategory {
            name,
            position,
            parent_id: parent,
            ..current
        })
    }
}

/// Refuses filing `child` under `parent` unless that keeps two levels.
async fn check_parent(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    child: ChannelCategoryId,
    parent: ChannelCategoryId,
) -> Result<(), CategoryWriteError> {
    if child == parent {
        return Err(CategoryWriteError::SelfParent);
    }
    let found = fetch_live_category(&mut **tx, parent)
        .await?
        .ok_or(CategoryWriteError::UnknownParent)?;
    if found.parent_id.is_some() {
        return Err(CategoryWriteError::ParentIsNested);
    }
    let has_children = sqlx::query_scalar!(
        r#"SELECT 1 AS "hit!: i64" FROM channel_categories
           WHERE parent_id = ? AND deleted_at IS NULL LIMIT 1"#,
        child
    )
    .fetch_optional(&mut **tx)
    .await?;
    if has_children.is_some() {
        return Err(CategoryWriteError::HasChildren);
    }
    Ok(())
}

/// One past the last live sibling's position under `parent`, leaving `except` out.
pub(super) async fn next_sibling_position(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    parent: Option<ChannelCategoryId>,
    except: Option<ChannelCategoryId>,
) -> Result<i64, sqlx::Error> {
    sqlx::query_scalar!(
        r#"SELECT COALESCE(MAX(position), -1) + 1 AS "next!: i64" FROM channel_categories
           WHERE deleted_at IS NULL AND parent_id IS ? AND id IS NOT ?"#,
        parent,
        except
    )
    .fetch_one(&mut **tx)
    .await
}

/// A live category by id over any executor.
pub(super) async fn fetch_live_category<'e, E>(
    executor: E,
    id: ChannelCategoryId,
) -> anyhow::Result<Option<ChannelCategory>>
where
    E: SqliteExecutor<'e>,
{
    Ok(fetch_category_by_id(executor, id)
        .await?
        .filter(|(_, live)| *live)
        .map(|(category, _)| category))
}

/// A category by id with whether it is live, for the id probe inside
/// [`Store::create_category_with_id`], which also matches a deleted row.
async fn fetch_category_by_id<'e, E>(
    executor: E,
    id: ChannelCategoryId,
) -> anyhow::Result<Option<(ChannelCategory, bool)>>
where
    E: SqliteExecutor<'e>,
{
    let row = sqlx::query!(
        r#"SELECT id AS "id!: ChannelCategoryId", name AS "name!",
                  position AS "position!: i64", created_at AS "created_at!",
                  parent_id AS "parent_id: ChannelCategoryId",
                  deleted_at IS NULL AS "live!: bool"
           FROM channel_categories WHERE id = ?"#,
        id
    )
    .fetch_optional(executor)
    .await?;
    Ok(row.map(|r| {
        let category = ChannelCategory {
            id: r.id,
            name: r.name,
            position: r.position,
            created_at: r.created_at,
            parent_id: r.parent_id,
        };
        (category, r.live)
    }))
}
