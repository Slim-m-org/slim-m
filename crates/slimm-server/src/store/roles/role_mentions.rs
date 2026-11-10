// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Resolving `@[Role Name]` mentions against the roles table.
//!
//! Split out of `roles.rs` (role CRUD) when that file reached the 500-line
//! ceiling: this is a read path for `push::recipients::resolved_mentions`,
//! not part of the role-management surface `http::roles` guards.

use std::collections::HashSet;

use super::super::Store;
use super::Role;

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
        let wanted: HashSet<String> = names.iter().map(|name| name.to_lowercase()).collect();
        let roles = self.list_roles().await?;
        Ok(roles
            .into_iter()
            .filter(|role| !role.is_everyone && wanted.contains(&role.name.to_lowercase()))
            .collect())
    }
}
