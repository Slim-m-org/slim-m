// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Setting the deployment's channel order, in the two shapes
//! `PUT /channels/order` accepts. [`Store::reorder_channels_flat`] is the
//! pre-category shape every client sent before docs/decisions/
//! 0006-channel-categories.md - a plain ordered list, positions only, every
//! channel's `category_id` left exactly as it was - kept working because the
//! wire is additive-only and reshaping an existing request is not additive.
//! [`Store::reorder_channels`] is the grouped shape that shape's decision
//! record adds: the whole rail, grouped by category, applied atomically so a
//! drag between two rail sections reassigns and repositions in one request
//! rather than a move followed by a reorder that could half-apply.

use std::collections::{HashMap, HashSet};

use super::{Channel, Store};
use crate::ids::{ChannelCategoryId, ChannelId};

/// One rail section's ordered contents, as submitted by a drag: the category
/// it names (`None` for the implicit uncategorised section) and every
/// channel now filed under it, in display order.
#[derive(Debug, Clone)]
pub struct ChannelOrderGroup {
    pub category_id: Option<ChannelCategoryId>,
    pub channel_ids: Vec<ChannelId>,
}

/// Why setting the channel order failed.
#[derive(Debug)]
pub enum ReorderChannelsError {
    /// The channel ids named (flattened, across every group for the grouped
    /// shape) did not add up to exactly the live, non-DM, non-thread
    /// channels: some were repeated, some live channels were left out, or
    /// some named ids are not live channels at all. `missing` and `extra`
    /// are each empty unless that half of the mismatch applies.
    Mismatch {
        missing: Vec<ChannelId>,
        extra: Vec<ChannelId>,
    },
    /// A group named a category id that is not a live category.
    UnknownCategory(Vec<ChannelCategoryId>),
    Internal(anyhow::Error),
}

impl From<sqlx::Error> for ReorderChannelsError {
    fn from(err: sqlx::Error) -> Self {
        ReorderChannelsError::Internal(err.into())
    }
}

impl From<anyhow::Error> for ReorderChannelsError {
    fn from(err: anyhow::Error) -> Self {
        ReorderChannelsError::Internal(err)
    }
}

/// The result of a successful reorder.
pub struct ReorderOutcome {
    /// Every live, non-DM channel, in its new order.
    pub channels: Vec<Channel>,
    /// Which channels actually changed category or position. A caller
    /// submitting the arrangement it already has gets an empty list rather
    /// than one claiming every channel moved - mirrors `edit_message`
    /// declining to mint a change nobody made.
    pub moved: Vec<ChannelId>,
}

/// Every live, non-DM, non-thread channel's id, category and position - the
/// one read both reorder shapes validate against and diff their target
/// arrangement from.
async fn live_channels(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
) -> Result<Vec<(ChannelId, Option<ChannelCategoryId>, i64)>, sqlx::Error> {
    let rows = sqlx::query!(
        r#"SELECT id AS "id!: ChannelId",
                  category_id AS "category_id: ChannelCategoryId",
                  position AS "position!: i64"
           FROM channels
           WHERE deleted_at IS NULL AND kind != 'dm' AND parent_message_id IS NULL"#
    )
    .fetch_all(&mut **tx)
    .await?;
    Ok(rows
        .into_iter()
        .map(|r| (r.id, r.category_id, r.position))
        .collect())
}

/// Refuses `ordered` unless it names exactly the ids in `live` - no more, no
/// fewer, no repeats - so a caller always knows whether its drag took
/// effect. Shared by both reorder shapes, since a flat list and a
/// flattened, grouped one are validated identically. `live` excludes the
/// channels the caller cannot see, so a refusal never names one.
fn validate_live_set(
    live: &[(ChannelId, Option<ChannelCategoryId>, i64)],
    ordered: &[ChannelId],
) -> Result<(), ReorderChannelsError> {
    let live_set: HashSet<ChannelId> = live.iter().map(|(id, ..)| *id).collect();
    let given_set: HashSet<ChannelId> = ordered.iter().copied().collect();
    if given_set.len() != ordered.len() || live_set != given_set {
        return Err(ReorderChannelsError::Mismatch {
            missing: live_set.difference(&given_set).copied().collect(),
            extra: given_set.difference(&live_set).copied().collect(),
        });
    }
    Ok(())
}

/// The live channels the caller may see: everything but `hidden`, which keeps
/// its place and is never named in a refusal.
fn visible_part(
    live: &[(ChannelId, Option<ChannelCategoryId>, i64)],
    hidden: &HashSet<ChannelId>,
) -> Vec<(ChannelId, Option<ChannelCategoryId>, i64)> {
    live.iter()
        .filter(|(id, ..)| !hidden.contains(id))
        .cloned()
        .collect()
}

/// `live` ids in current display order within one category (`Some(c)`), one
/// section (`None`), or all of it (`any`).
fn current_order(
    live: &[(ChannelId, Option<ChannelCategoryId>, i64)],
    section: Option<Option<ChannelCategoryId>>,
) -> Vec<ChannelId> {
    let mut rows: Vec<_> = live
        .iter()
        .filter(|(_, category, _)| section.is_none_or(|s| s == *category))
        .collect();
    rows.sort_by_key(|(id, _, position)| (*position, id.0));
    rows.into_iter().map(|(id, ..)| *id).collect()
}

/// `shown` with every `hidden` channel put back at the index it holds in
/// `current` (clamped to the end), so a caller who cannot see a channel
/// neither moves it nor learns where it sits.
fn splice_hidden(
    mut shown: Vec<ChannelId>,
    current: &[ChannelId],
    hidden: &HashSet<ChannelId>,
) -> Vec<ChannelId> {
    for (index, id) in current.iter().enumerate() {
        if hidden.contains(id) {
            shown.insert(index.min(shown.len()), *id);
        }
    }
    shown
}

impl Store {
    /// Sets the deployment's channel order to exactly `ordered`, position `i`
    /// for the channel at index `i`, leaving every channel's existing
    /// `category_id` completely untouched.
    ///
    /// This is the pre-category shape, kept working rather than replaced:
    /// a global monotonic index still expresses each category's own relative
    /// order correctly, because `list_channels`'s `ORDER BY category
    /// position, channel position` only ever compares two channels sharing a
    /// category, and a monotonic index preserves relative order within any
    /// subsequence of itself. So an old client that has never heard of
    /// categories can still drag a channel's position within whichever
    /// category it already sits in.
    ///
    /// Refuses a list that is not exactly the live, non-DM, non-thread
    /// channels, the same validation [`Store::reorder_channels`] applies to
    /// its own flattened set.
    pub async fn reorder_channels_flat(
        &self,
        ordered: &[ChannelId],
    ) -> Result<ReorderOutcome, ReorderChannelsError> {
        self.reorder_channels_flat_around(ordered, &HashSet::new())
            .await
    }

    /// [`Self::reorder_channels_flat`] for a caller who cannot see the
    /// `hidden` channels: `ordered` names only the rest, and each hidden
    /// channel keeps its current slot in the global order.
    pub async fn reorder_channels_flat_around(
        &self,
        ordered: &[ChannelId],
        hidden: &HashSet<ChannelId>,
    ) -> Result<ReorderOutcome, ReorderChannelsError> {
        let mut tx = self.begin_write().await?;
        let live = live_channels(&mut tx).await?;
        validate_live_set(&visible_part(&live, hidden), ordered)?;
        let ordered = &splice_hidden(ordered.to_vec(), &current_order(&live, None), hidden);

        let before_position: HashMap<ChannelId, i64> = live
            .into_iter()
            .map(|(id, _, position)| (id, position))
            .collect();

        let mut moved = Vec::new();
        for (position, id) in ordered.iter().enumerate() {
            let position = position as i64;
            if before_position.get(id) == Some(&position) {
                continue;
            }
            moved.push(*id);
            sqlx::query!(
                "UPDATE channels SET position = ? WHERE id = ?",
                position,
                id
            )
            .execute(&mut *tx)
            .await?;
        }
        tx.commit().await?;

        let channels = self.list_channels().await?;
        Ok(ReorderOutcome { channels, moved })
    }

    /// Sets the deployment's channel order and category placement to exactly
    /// `groups`: position `i` and `group.category_id` for the channel at
    /// index `i` of `group.channel_ids`. Refuses a set of groups whose
    /// channel ids, flattened, are not exactly the live, non-DM, non-thread
    /// channels - too few would leave a gap nothing else fills, too many or a
    /// repeat names something this route cannot place - so a caller always
    /// knows whether its drag actually took effect. Also refuses a group
    /// naming a category id that is not a live category, before writing
    /// anything.
    ///
    /// One transaction from the first read (see [`Store::begin_write`]), so a
    /// concurrent create, delete, or category delete cannot land between the
    /// validation and the write and silently invalidate it.
    pub async fn reorder_channels(
        &self,
        groups: &[ChannelOrderGroup],
    ) -> Result<ReorderOutcome, ReorderChannelsError> {
        self.reorder_channels_around(groups, &HashSet::new()).await
    }

    /// [`Self::reorder_channels`] for a caller who cannot see the `hidden`
    /// channels: `groups` names only the rest, and each hidden channel stays
    /// in its own section at the index it already holds there.
    pub async fn reorder_channels_around(
        &self,
        groups: &[ChannelOrderGroup],
        hidden: &HashSet<ChannelId>,
    ) -> Result<ReorderOutcome, ReorderChannelsError> {
        let mut tx = self.begin_write().await?;
        let live = live_channels(&mut tx).await?;

        let ordered: Vec<ChannelId> = groups
            .iter()
            .flat_map(|group| group.channel_ids.iter().copied())
            .collect();
        validate_live_set(&visible_part(&live, hidden), &ordered)?;
        let groups: Vec<ChannelOrderGroup> = groups
            .iter()
            .map(|group| ChannelOrderGroup {
                category_id: group.category_id,
                channel_ids: splice_hidden(
                    group.channel_ids.clone(),
                    &current_order(&live, Some(group.category_id)),
                    hidden,
                ),
            })
            .collect();

        let named_categories: HashSet<ChannelCategoryId> = groups
            .iter()
            .filter_map(|group| group.category_id)
            .collect();
        if !named_categories.is_empty() {
            let live_categories: HashSet<ChannelCategoryId> = sqlx::query_scalar!(
                r#"SELECT id AS "id!: ChannelCategoryId" FROM channel_categories
                   WHERE deleted_at IS NULL"#
            )
            .fetch_all(&mut *tx)
            .await?
            .into_iter()
            .collect();
            let unknown: Vec<ChannelCategoryId> = named_categories
                .difference(&live_categories)
                .copied()
                .collect();
            if !unknown.is_empty() {
                return Err(ReorderChannelsError::UnknownCategory(unknown));
            }
        }

        let before: HashMap<ChannelId, (Option<ChannelCategoryId>, i64)> = live
            .into_iter()
            .map(|(id, category_id, position)| (id, (category_id, position)))
            .collect();

        let mut moved = Vec::new();
        for group in &groups {
            for (position, id) in group.channel_ids.iter().enumerate() {
                let position = position as i64;
                let target = (group.category_id, position);
                if before.get(id) == Some(&target) {
                    continue;
                }
                moved.push(*id);
                sqlx::query!(
                    "UPDATE channels SET category_id = ?, position = ? WHERE id = ?",
                    group.category_id,
                    position,
                    id
                )
                .execute(&mut *tx)
                .await?;
            }
        }
        tx.commit().await?;

        let channels = self.list_channels().await?;
        Ok(ReorderOutcome { channels, moved })
    }
}
