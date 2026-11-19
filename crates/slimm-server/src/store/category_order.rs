// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The whole category arrangement at once, what `PUT /categories/order`
//! applies for a drag (decision 0120).

use std::collections::{HashMap, HashSet};

use super::{ChannelCategory, Store};
use crate::ids::ChannelCategoryId;

/// One sibling group in display order: the top level (`parent_id` `None`), or
/// one top-level category's sub-categories.
#[derive(Debug, Clone)]
pub struct CategoryOrderGroup {
    pub parent_id: Option<ChannelCategoryId>,
    pub category_ids: Vec<ChannelCategoryId>,
}

/// Why an arrangement was refused, before anything was written.
#[derive(Debug)]
pub enum ReorderCategoriesError {
    /// Two groups named the same parent, or there were two top-level groups.
    RepeatedParent,
    /// The ids named, flattened, were not exactly the live categories.
    Mismatch {
        missing: Vec<ChannelCategoryId>,
        extra: Vec<ChannelCategoryId>,
    },
    /// A group's parent is not a live category.
    UnknownParent(Vec<ChannelCategoryId>),
    /// A group's parent is not in the top-level group, which would be a third level.
    TooDeep(Vec<ChannelCategoryId>),
    Internal(anyhow::Error),
}

impl From<sqlx::Error> for ReorderCategoriesError {
    fn from(err: sqlx::Error) -> Self {
        Self::Internal(err.into())
    }
}

impl From<anyhow::Error> for ReorderCategoriesError {
    fn from(err: anyhow::Error) -> Self {
        Self::Internal(err)
    }
}

/// The result of a successful arrangement.
pub struct CategoryReorderOutcome {
    /// Every live category, in tree order.
    pub categories: Vec<ChannelCategory>,
    /// The categories whose parent or position changed; empty for a no-op.
    pub moved: Vec<ChannelCategoryId>,
}

type Placement = (Option<ChannelCategoryId>, i64);

impl Store {
    /// Applies `groups` in one transaction, position `i` to index `i`; a
    /// re-parented category keeps its overwrites and stops being synced.
    pub async fn reorder_categories(
        &self,
        groups: &[CategoryOrderGroup],
    ) -> Result<CategoryReorderOutcome, ReorderCategoriesError> {
        self.reorder_categories_around(groups, &HashSet::new(), &HashSet::new())
            .await
    }

    /// [`Self::reorder_categories`] for a caller kept from the `hidden` categories: `groups`
    /// names only the rest, and each hidden one keeps its parent and its index among its siblings.
    /// The `fixed` ones may be named but stay where they are, as a hidden one does.
    pub async fn reorder_categories_around(
        &self,
        groups: &[CategoryOrderGroup],
        hidden: &HashSet<ChannelCategoryId>,
        fixed: &HashSet<ChannelCategoryId>,
    ) -> Result<CategoryReorderOutcome, ReorderCategoriesError> {
        let mut tx = self.begin_write().await?;
        let before = live_placements(&mut tx).await?;
        let shown: HashMap<ChannelCategoryId, Placement> = before
            .iter()
            .filter(|(id, _)| !hidden.contains(id))
            .map(|(id, placement)| (*id, *placement))
            .collect();
        validate(groups, &shown)?;
        let unmoved: Vec<CategoryOrderGroup> = groups
            .iter()
            .map(|group| CategoryOrderGroup {
                parent_id: group.parent_id,
                category_ids: group
                    .category_ids
                    .iter()
                    .filter(|id| !fixed.contains(id))
                    .copied()
                    .collect(),
            })
            .collect();
        let kept: HashSet<ChannelCategoryId> = hidden.union(fixed).copied().collect();
        let groups = &with_hidden(&unmoved, &before, &kept);
        validate(groups, &before)?;

        let target: Vec<(ChannelCategoryId, Placement)> = groups
            .iter()
            .flat_map(|group| {
                (0_i64..)
                    .zip(&group.category_ids)
                    .map(|(position, id)| (*id, (group.parent_id, position)))
            })
            .collect();

        // Clearing every changed parent first keeps the depth trigger from seeing a half-moved tree.
        for (id, (parent, _)) in &target {
            let was = before[id].0;
            if was.is_some() && was != *parent {
                sqlx::query!(
                    "UPDATE channel_categories SET parent_id = NULL, permissions_synced = 0
                     WHERE id = ?",
                    id
                )
                .execute(&mut *tx)
                .await?;
            }
        }
        let mut moved = Vec::new();
        for (id, placement) in &target {
            let was = before[id];
            if was == *placement {
                continue;
            }
            moved.push(*id);
            let (parent, position) = *placement;
            if was.0 == parent {
                sqlx::query!(
                    "UPDATE channel_categories SET position = ? WHERE id = ?",
                    position,
                    id
                )
                .execute(&mut *tx)
                .await?;
            } else {
                sqlx::query!(
                    "UPDATE channel_categories
                     SET parent_id = ?, position = ?, permissions_synced = 0 WHERE id = ?",
                    parent,
                    position,
                    id
                )
                .execute(&mut *tx)
                .await?;
            }
        }
        tx.commit().await?;

        let categories = self.list_categories().await?;
        Ok(CategoryReorderOutcome { categories, moved })
    }
}

async fn live_placements(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
) -> Result<HashMap<ChannelCategoryId, Placement>, sqlx::Error> {
    let rows = sqlx::query!(
        r#"SELECT id AS "id!: ChannelCategoryId",
                  parent_id AS "parent_id: ChannelCategoryId",
                  position AS "position!: i64"
           FROM channel_categories WHERE deleted_at IS NULL"#
    )
    .fetch_all(&mut **tx)
    .await?;
    Ok(rows
        .into_iter()
        .map(|r| (r.id, (r.parent_id, r.position)))
        .collect())
}

/// `groups` with each `hidden` category put back under its current parent at the index it holds
/// among its siblings there, adding a group for a parent the caller named nothing under.
fn with_hidden(
    groups: &[CategoryOrderGroup],
    live: &HashMap<ChannelCategoryId, Placement>,
    hidden: &HashSet<ChannelCategoryId>,
) -> Vec<CategoryOrderGroup> {
    let mut full = groups.to_vec();
    for id in hidden {
        let Some((parent, _)) = live.get(id) else {
            continue;
        };
        if !full.iter().any(|group| group.parent_id == *parent) {
            full.push(CategoryOrderGroup {
                parent_id: *parent,
                category_ids: Vec::new(),
            });
        }
    }
    for group in &mut full {
        let mut siblings: Vec<(i64, ChannelCategoryId)> = live
            .iter()
            .filter(|(_, (parent, _))| *parent == group.parent_id)
            .map(|(id, (_, position))| (*position, *id))
            .collect();
        siblings.sort();
        for (index, (_, id)) in siblings.into_iter().enumerate() {
            if hidden.contains(&id) {
                let index = index.min(group.category_ids.len());
                group.category_ids.insert(index, id);
            }
        }
    }
    full
}

/// Every refusal, checked before anything is written; see [`ReorderCategoriesError`].
fn validate(
    groups: &[CategoryOrderGroup],
    live: &HashMap<ChannelCategoryId, Placement>,
) -> Result<(), ReorderCategoriesError> {
    let mut parents = HashSet::new();
    if !groups.iter().all(|group| parents.insert(group.parent_id)) {
        return Err(ReorderCategoriesError::RepeatedParent);
    }

    let named: Vec<ChannelCategoryId> = groups
        .iter()
        .flat_map(|group| group.category_ids.iter().copied())
        .collect();
    let named_set: HashSet<ChannelCategoryId> = named.iter().copied().collect();
    let live_set: HashSet<ChannelCategoryId> = live.keys().copied().collect();
    if named_set.len() != named.len() || named_set != live_set {
        let mut seen = HashSet::new();
        let mut extra: Vec<ChannelCategoryId> = named_set.difference(&live_set).copied().collect();
        extra.extend(named.iter().filter(|id| !seen.insert(**id)));
        extra.sort();
        extra.dedup();
        let mut missing: Vec<ChannelCategoryId> =
            live_set.difference(&named_set).copied().collect();
        missing.sort();
        return Err(ReorderCategoriesError::Mismatch { missing, extra });
    }

    let mut unknown: Vec<ChannelCategoryId> = parents
        .iter()
        .flatten()
        .filter(|parent| !live_set.contains(parent))
        .copied()
        .collect();
    if !unknown.is_empty() {
        unknown.sort();
        return Err(ReorderCategoriesError::UnknownParent(unknown));
    }

    let top_level: HashSet<ChannelCategoryId> = groups
        .iter()
        .filter(|group| group.parent_id.is_none())
        .flat_map(|group| group.category_ids.iter().copied())
        .collect();
    let mut too_deep: Vec<ChannelCategoryId> = parents
        .iter()
        .flatten()
        .filter(|parent| !top_level.contains(parent))
        .copied()
        .collect();
    if !too_deep.is_empty() {
        too_deep.sort();
        return Err(ReorderCategoriesError::TooDeep(too_deep));
    }
    Ok(())
}
