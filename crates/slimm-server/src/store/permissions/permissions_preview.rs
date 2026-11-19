// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What one role sees: the channel rows a member holding only `@everyone` and that role would be
//! listed, through the same evaluator `GET /channels` runs (decision 0124).

use std::collections::HashSet;

use super::super::{Channel, Role, Store};
use super::RoleContext;
use crate::ids::ChannelCategoryId;
use crate::permissions::Permissions;

/// A role's view of the server: its deployment-level grant and every live channel with its bits.
pub struct RolePreview {
    pub base: Permissions,
    /// Every live channel, viewable or not, paired with its bits and whether `@everyone` lacks view.
    pub channels: Vec<(Channel, Permissions, bool)>,
    /// The live categories whose own rows let the role view them.
    pub categories: HashSet<ChannelCategoryId>,
}

impl Store {
    /// Never the owner, no member overwrite, no timeout and no join gate: `@everyone` plus `role`.
    pub async fn preview_role(&self, role: &Role) -> anyhow::Result<RolePreview> {
        let (everyone_id, everyone_perms) = self.everyone_role().await?;
        let roles = match role.is_everyone {
            true => RoleContext {
                everyone_id,
                everyone_perms,
                ..RoleContext::none()
            },
            false => RoleContext {
                everyone_id,
                everyone_perms,
                role_perms: vec![role.permissions],
                role_ids: vec![role.id.0],
                owner: false,
            },
        };
        let base = roles.base();
        let channels = self.list_channels().await?;
        let channels = self
            .evaluate_channels(channels, &roles, None, |_| Permissions::NONE)
            .await?;
        let categories = self
            .categories_viewable_as(&roles, None, Permissions::NONE)
            .await?;
        Ok(RolePreview {
            base,
            channels,
            categories,
        })
    }
}
