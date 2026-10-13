// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Resolving `@[Role Name]` mentions against the roles table.
//!
//! Split out of `roles.rs` (role CRUD) when that file reached the 500-line
//! ceiling: this is a read path for `push::recipients::resolved_mentions`,
//! not part of the role-management surface `http::roles` guards.

use sqlx::{QueryBuilder, Row};

use super::Store;
use super::roles::Role;

impl Store {
    /// Roles named (case-insensitively) any of `names`, excluding
    /// `@everyone` - the resolver for `@[Role Name]` mentions. Case
    /// insensitivity mirrors [`Store::user_ids_for_usernames`]; `@everyone`
    /// is excluded for the same reason [`Store::roles_for_users`] excludes
    /// it, plus one more: that role's own wake-up path is the reserved
    /// `@everyone`/`@here` words, gated on `Permissions::MENTION_EVERYONE`
    /// directly (`Permissions` from `crate::permissions`), and letting
    /// `@[everyone]` reach the same members through a role's own (possibly
    /// unset) `mentionable` flag would be a second, weaker gate on the
    /// identical blast radius.
    pub async fn roles_for_names(&self, names: &[String]) -> anyhow::Result<Vec<Role>> {
        if names.is_empty() {
            return Ok(Vec::new());
        }

        let mut builder = QueryBuilder::new(
            "SELECT id, name, permissions, is_everyone, mentionable, created_at, \
                    managed_bot_id, position, hoist, color \
             FROM roles WHERE is_everyone = 0 AND LOWER(name) IN (",
        );
        let mut separated = builder.separated(", ");
        for name in names {
            separated.push_bind(name.to_lowercase());
        }
        builder.push(")");

        let rows = builder.build().fetch_all(&self.pool).await?;
        rows.into_iter()
            .map(|row| {
                Ok(Role {
                    id: row.try_get("id")?,
                    name: row.try_get("name")?,
                    permissions: row.try_get("permissions")?,
                    is_everyone: row.try_get::<i64, _>("is_everyone")? != 0,
                    mentionable: row.try_get::<i64, _>("mentionable")? != 0,
                    created_at: row.try_get("created_at")?,
                    managed_bot_id: row.try_get("managed_bot_id")?,
                    position: row.try_get("position")?,
                    hoist: row.try_get::<i64, _>("hoist")? != 0,
                    color: row.try_get("color")?,
                })
            })
            .collect::<Result<Vec<_>, sqlx::Error>>()
            .map_err(Into::into)
    }
}
