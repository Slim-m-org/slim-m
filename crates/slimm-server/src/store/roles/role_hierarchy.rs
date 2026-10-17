// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Per-role member counts and the position ceiling a reorder is checked
//! against. Split out of `roles.rs` when that file reached the 500-line
//! ceiling.

use std::collections::HashMap;

use super::super::{Role, Store};
use crate::ids::{RoleId, UserId};

/// A role alongside how many members currently hold it, for the roles pane's
/// list - it names each role's count beside it, so a naive "list roles, then
/// count each one's members" would be exactly the N+1 the batched reads
/// elsewhere in this module exist to avoid.
pub struct RoleWithCount {
    pub role: Role,
    pub member_count: i64,
}

impl Store {
    /// Every role with its member count, in the same order [`Store::list_roles`]
    /// returns them, in three queries total regardless of how many roles
    /// exist: the role list itself, one grouped count over `member_roles`,
    /// and [`Store::member_count`] for `@everyone`, which every live member
    /// holds without an explicit row in that table.
    pub async fn list_roles_with_member_counts(&self) -> anyhow::Result<Vec<RoleWithCount>> {
        let roles = self.list_roles().await?;
        let rows = sqlx::query!(
            r#"SELECT role_id AS "role_id!: RoleId", COUNT(*) AS "count!: i64"
               FROM member_roles GROUP BY role_id"#
        )
        .fetch_all(&self.pool)
        .await?;
        let mut counts: HashMap<RoleId, i64> =
            rows.into_iter().map(|r| (r.role_id, r.count)).collect();
        let everyone_count = self.member_count().await?;

        Ok(roles
            .into_iter()
            .map(|role| {
                let member_count = if role.is_everyone {
                    everyone_count
                } else {
                    counts.remove(&role.id).unwrap_or(0)
                };
                RoleWithCount { role, member_count }
            })
            .collect())
    }

    /// One role's member count, for a create/update response that has
    /// already paid for the role row and does not want a second full list
    /// just to report this. `@everyone` still routes through
    /// [`Store::member_count`], the same special case
    /// [`Store::list_roles_with_member_counts`] applies.
    pub async fn member_count_for_role(&self, role: &Role) -> anyhow::Result<i64> {
        if role.is_everyone {
            return self.member_count().await;
        }
        let count = sqlx::query_scalar!(
            r#"SELECT COUNT(*) AS "count!: i64" FROM member_roles WHERE role_id = ?"#,
            role.id
        )
        .fetch_one(&self.pool)
        .await?;
        Ok(count)
    }

    /// The highest `position` among the roles `user_id` currently holds
    /// through `member_roles` - never `@everyone`, which is not held
    /// explicitly and would only ever contribute its bootstrap default. This
    /// is the ceiling `http::role_reorder`'s escalation guard compares a
    /// reorder against, the position-hierarchy sibling of
    /// `http::escalation::escalation_guard`'s bit comparison. `None` if the
    /// user holds no role beyond `@everyone`.
    pub async fn highest_role_position(&self, user_id: UserId) -> anyhow::Result<Option<i64>> {
        let position = sqlx::query_scalar!(
            r#"SELECT MAX(r.position) AS "position: i64" FROM member_roles mr
               JOIN roles r ON r.id = mr.role_id WHERE mr.user_id = ?"#,
            user_id
        )
        .fetch_one(&self.pool)
        .await?;
        Ok(position)
    }
}
