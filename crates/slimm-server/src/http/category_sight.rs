// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Which categories one caller is listed (decisions 0064 and 0120). Every category route judges
//! a category by this one set, so a category kept from a channel manager answers each of them
//! exactly as one that does not exist; only ADMINISTRATOR sees them all (decision 0011).

use std::collections::HashSet;

use super::AppState;
use super::error::ApiError;
use crate::ids::{ChannelCategoryId, UserId};
use crate::permissions::Permissions;
use crate::store::ChannelCategory;

/// Every live category in tree order, and the ids of those the caller is listed.
pub(super) struct CategorySight {
    pub(super) categories: Vec<ChannelCategory>,
    pub(super) listed: HashSet<ChannelCategoryId>,
}

impl CategorySight {
    /// Each category holding a channel the caller can view, each one a channel manager may view
    /// by its own rows, and the parent of every such sub-category, shown only as its heading.
    pub(super) async fn of(state: &AppState, user_id: UserId) -> Result<Self, ApiError> {
        let categories = state.store.list_categories().await?;
        let base = state.store.base_permissions(user_id).await?;
        if base.contains(Permissions::ADMINISTRATOR) {
            let listed = categories.iter().map(|c| c.id).collect();
            return Ok(Self { categories, listed });
        }
        let mut holding: HashSet<ChannelCategoryId> = state
            .store
            .visible_channels(user_id)
            .await?
            .into_iter()
            .filter_map(|channel| channel.category_id)
            .collect();
        if base.contains(Permissions::MANAGE_CHANNELS) {
            holding.extend(state.store.categories_viewable_by(user_id).await?);
        }
        let listed = with_parents(&categories, &holding);
        Ok(Self { categories, listed })
    }

    /// Whether `id` names a live category the caller is not listed.
    pub(super) fn hides(&self, id: ChannelCategoryId) -> bool {
        !self.listed.contains(&id) && self.categories.iter().any(|c| c.id == id)
    }

    /// The live categories the caller is not listed.
    pub(super) fn hidden(&self) -> HashSet<ChannelCategoryId> {
        let ids = self.categories.iter().map(|c| c.id);
        ids.filter(|id| !self.listed.contains(id)).collect()
    }
}

/// `holding` and the parent of each category in it: the closure runs upward only.
pub(super) fn with_parents(
    categories: &[ChannelCategory],
    holding: &HashSet<ChannelCategoryId>,
) -> HashSet<ChannelCategoryId> {
    let parents = categories
        .iter()
        .filter(|c| holding.contains(&c.id))
        .filter_map(|c| c.parent_id);
    parents.chain(holding.iter().copied()).collect()
}
