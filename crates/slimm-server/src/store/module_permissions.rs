// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The dynamic, module-scoped permission registry and its grants: the one
//! real extension the core permission model needs for modules, per
//! docs/decisions/0021-modules-and-the-dock.md. A module's declared
//! permissions live in `module_permissions` (see `store::modules` for how
//! they get there); which role holds one lives in `role_module_permissions`,
//! the module-scoped parallel to `roles.permissions`'s bitmask.
//!
//! [`Store::user_has_module_permission`] is the runtime's live gate: every
//! route that runs or lists a module's extension points (`http::module_commands`,
//! `http::apps`) resolves the caller's grant through it before anything runs.

use std::collections::HashSet;

use uuid::Uuid;

use super::Store;
use crate::ids::{RoleId, UserId};

/// One grantable module permission, joined to its module's current display
/// name so a role editor can label the row without a second lookup.
pub struct ModulePermission {
    pub module_id: String,
    pub module_name: String,
    pub perm_key: String,
    pub name: String,
    pub description: String,
}

/// One role's existing grant of a module permission: just enough to key a
/// revoke or to render a checked row.
pub struct GrantedModulePermission {
    pub module_id: String,
    pub perm_key: String,
}

/// Why granting a module permission to a role was refused.
#[derive(Debug)]
pub enum GrantModulePermissionError {
    /// No module currently declares this `(module_id, perm_key)` pair -
    /// checked explicitly rather than left to the foreign key, so the
    /// caller gets a clean 404 instead of a raw constraint failure.
    UnknownPermission,
    Internal(anyhow::Error),
}

impl From<sqlx::Error> for GrantModulePermissionError {
    fn from(err: sqlx::Error) -> Self {
        GrantModulePermissionError::Internal(err.into())
    }
}

impl Store {
    /// Every module permission currently registered, across every installed
    /// module - the grantable rows a role editor lists alongside core
    /// permissions, namespaced by `module_id`. Includes a disabled module's
    /// permissions: an existing grant on one stays meaningful even while the
    /// module itself is off, so the row stays visible rather than vanishing
    /// out from under an editor.
    pub async fn list_module_permissions(&self) -> anyhow::Result<Vec<ModulePermission>> {
        let rows = sqlx::query!(
            r#"SELECT mp.module_id AS "module_id!", im.name AS "module_name!",
                      mp.perm_key AS "perm_key!", mp.name AS "name!",
                      mp.description AS "description!"
               FROM module_permissions mp
               JOIN installed_modules im ON im.id = mp.module_id
               ORDER BY im.name, mp.perm_key"#
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .into_iter()
            .map(|r| ModulePermission {
                module_id: r.module_id,
                module_name: r.module_name,
                perm_key: r.perm_key,
                name: r.name,
                description: r.description,
            })
            .collect())
    }

    /// The module permissions a role currently holds.
    pub async fn role_module_permissions(
        &self,
        role_id: RoleId,
    ) -> anyhow::Result<Vec<GrantedModulePermission>> {
        let rows = sqlx::query!(
            r#"SELECT module_id AS "module_id!", perm_key AS "perm_key!"
               FROM role_module_permissions WHERE role_id = ?"#,
            role_id
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .into_iter()
            .map(|r| GrantedModulePermission {
                module_id: r.module_id,
                perm_key: r.perm_key,
            })
            .collect())
    }

    /// Grants a module permission to a role. Idempotent. Refuses a
    /// `(module_id, perm_key)` no installed module currently declares.
    pub async fn grant_module_permission(
        &self,
        role_id: RoleId,
        module_id: &str,
        perm_key: &str,
    ) -> Result<(), GrantModulePermissionError> {
        let mut tx = self.begin_write().await?;
        let exists = sqlx::query_scalar!(
            r#"SELECT 1 AS "one!: i64" FROM module_permissions
               WHERE module_id = ? AND perm_key = ?"#,
            module_id,
            perm_key
        )
        .fetch_optional(&mut *tx)
        .await?;
        if exists.is_none() {
            return Err(GrantModulePermissionError::UnknownPermission);
        }
        sqlx::query!(
            "INSERT OR IGNORE INTO role_module_permissions (role_id, module_id, perm_key)
             VALUES (?, ?, ?)",
            role_id,
            module_id,
            perm_key
        )
        .execute(&mut *tx)
        .await?;
        tx.commit().await?;
        Ok(())
    }

    /// Revokes a module permission from a role. Idempotent: revoking one not
    /// held still succeeds, the same as [`Store::unassign_role`].
    pub async fn revoke_module_permission(
        &self,
        role_id: RoleId,
        module_id: &str,
        perm_key: &str,
    ) -> anyhow::Result<()> {
        sqlx::query!(
            "DELETE FROM role_module_permissions
             WHERE role_id = ? AND module_id = ? AND perm_key = ?",
            role_id,
            module_id,
            perm_key
        )
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// Every `(module_id, perm_key)` `user_id` holds, in one round trip.
    ///
    /// The batched form of [`Store::user_has_module_permission`], for the
    /// discovery loop in `http::module_commands` that asks the same question
    /// once per extension point. Asking singly re-ran `load_roles` - two
    /// queries - plus a lookup for every point of every installed module, for
    /// the same caller and the same role set each time, on a route the composer
    /// refetches whenever it remounts. This is two queries regardless of how
    /// many modules the deployment has installed.
    ///
    /// Does not bypass for `Permissions::ADMINISTRATOR`, for the reason given
    /// on [`Store::user_has_module_permission`].
    pub async fn held_module_permissions(
        &self,
        user_id: UserId,
    ) -> anyhow::Result<HashSet<(String, String)>> {
        let roles = self.load_roles(user_id).await?;
        let mut role_ids: Vec<Uuid> = roles.role_ids;
        role_ids.extend(roles.everyone_id);
        if role_ids.is_empty() {
            return Ok(HashSet::new());
        }

        use sqlx::QueryBuilder;
        let mut builder = QueryBuilder::new(
            "SELECT DISTINCT module_id, perm_key FROM role_module_permissions WHERE role_id IN (",
        );
        let mut separated = builder.separated(", ");
        for id in &role_ids {
            separated.push_bind(*id);
        }
        builder.push(")");

        use sqlx::Row;
        let rows = builder.build().fetch_all(&self.pool).await?;
        rows.into_iter()
            .map(|row| Ok((row.try_get("module_id")?, row.try_get("perm_key")?)))
            .collect()
    }

    /// Whether `user_id` holds `(module_id, perm_key)` through any role they
    /// carry, `@everyone` included. The module runtime's live gate: it answers
    /// "may this user do X" for a module's own declared permission without
    /// ever seeing the core bitmask.
    ///
    /// Deliberately does not bypass for `Permissions::ADMINISTRATOR`: module
    /// permissions are a separate, module-scoped namespace the core
    /// evaluator never resolves, so an administrator sees this the same way
    /// every other role does, by holding the grant like anyone else.
    pub async fn user_has_module_permission(
        &self,
        user_id: UserId,
        module_id: &str,
        perm_key: &str,
    ) -> anyhow::Result<bool> {
        let roles = self.load_roles(user_id).await?;
        let mut role_ids: Vec<Uuid> = roles.role_ids;
        role_ids.extend(roles.everyone_id);
        if role_ids.is_empty() {
            return Ok(false);
        }

        use sqlx::QueryBuilder;
        let mut builder =
            QueryBuilder::new("SELECT 1 FROM role_module_permissions WHERE module_id = ");
        builder.push_bind(module_id);
        builder.push(" AND perm_key = ").push_bind(perm_key);
        builder.push(" AND role_id IN (");
        let mut separated = builder.separated(", ");
        for id in &role_ids {
            separated.push_bind(*id);
        }
        builder.push(")");

        let row = builder.build().fetch_optional(&self.pool).await?;
        Ok(row.is_some())
    }
}
