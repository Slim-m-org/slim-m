// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The `hoist` flag and the per-member top hoisted role the member pane
//! sections on; split out of `roles.rs`, which sits at the line ceiling.

use std::collections::HashMap;

use sqlx::{QueryBuilder, Row};

use super::Store;
use crate::ids::{RoleId, UserId};

/// The hoisted role a member is listed under: the highest-position one they hold.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HoistedRole {
    pub id: RoleId,
    pub position: i64,
}

impl Store {
    /// Each given member's top hoisted role in one query; members with none are absent.
    ///
    /// Ordered exactly as [`Store::roles_for_users`] orders a member's roles, so
    /// the two never disagree about which role is on top.
    pub async fn hoisted_roles_for_users(
        &self,
        user_ids: &[UserId],
    ) -> anyhow::Result<HashMap<UserId, HoistedRole>> {
        if user_ids.is_empty() {
            return Ok(HashMap::new());
        }
        let mut builder = QueryBuilder::new(
            "SELECT mr.user_id AS user_id, r.id AS role_id, r.position AS position \
             FROM member_roles mr JOIN roles r ON r.id = mr.role_id \
             WHERE r.is_everyone = 0 AND r.hoist = 1 AND mr.user_id IN (",
        );
        let mut separated = builder.separated(", ");
        for id in user_ids {
            separated.push_bind(*id);
        }
        builder.push(") ORDER BY mr.user_id, r.position DESC, r.created_at");

        let mut top = HashMap::new();
        for row in builder.build().fetch_all(&self.pool).await? {
            let user_id: UserId = row.try_get("user_id")?;
            top.entry(user_id).or_insert(HoistedRole {
                id: row.try_get("role_id")?,
                position: row.try_get("position")?,
            });
        }
        Ok(top)
    }
}
