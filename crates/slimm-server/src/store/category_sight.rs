// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Which live categories a principal may view by each category's own rows, as a channel synced
//! to it would be viewed (decision 0064): what lists an empty category to a channel manager.

use std::collections::{HashMap, HashSet};

use uuid::Uuid;

use super::Store;
use super::permissions::{ChannelOverwrite, RoleContext};
use crate::ids::{ChannelCategoryId, UserId};
use crate::permissions::Permissions;

impl Store {
    /// The live categories whose rows let `user_id` view them, less a timeout or the join gate.
    pub async fn categories_viewable_by(
        &self,
        user_id: UserId,
    ) -> anyhow::Result<HashSet<ChannelCategoryId>> {
        let roles = self.load_roles(user_id).await?;
        let deny = self.member_deny(user_id, None).await?;
        self.categories_viewable_as(&roles, Some(user_id), deny)
            .await
    }

    /// [`Self::categories_viewable_by`] for `roles`, which a role preview builds with no member.
    pub(super) async fn categories_viewable_as(
        &self,
        roles: &RoleContext,
        member: Option<UserId>,
        deny: Permissions,
    ) -> anyhow::Result<HashSet<ChannelCategoryId>> {
        let rows = sqlx::query!(
            r#"SELECT c.id AS "category_id!: ChannelCategoryId",
                      o.target_type AS "target_type?",
                      o.target_id AS "target_id?: Uuid",
                      o.allow AS "allow?: Permissions",
                      o.deny AS "deny?: Permissions"
               FROM channel_categories c
               LEFT JOIN category_overwrites o ON o.category_id = c.id
               WHERE c.deleted_at IS NULL"#
        )
        .fetch_all(&self.pool)
        .await?;
        let mut by_category: HashMap<ChannelCategoryId, Vec<ChannelOverwrite>> = HashMap::new();
        for row in rows {
            let overwrites = by_category.entry(row.category_id).or_default();
            if let (Some(target_type), Some(target_id), Some(allow), Some(deny)) =
                (row.target_type, row.target_id, row.allow, row.deny)
            {
                overwrites.push(ChannelOverwrite {
                    target_type,
                    target_id,
                    allow,
                    deny,
                });
            }
        }
        Ok(by_category
            .into_iter()
            .filter(|(_, overwrites)| {
                roles
                    .evaluate_as(member, overwrites)
                    .permissions
                    .remove(deny)
                    .contains(Permissions::VIEW_CHANNEL)
            })
            .map(|(id, _)| id)
            .collect())
    }
}
