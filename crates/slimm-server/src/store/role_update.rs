// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The one write behind `PATCH /roles/{id}`, split from `roles.rs` for the file budget.

use sqlx::QueryBuilder;

use super::Store;
use super::roles::{Role, RoleGuardError, administrator_count};
use crate::ids::RoleId;
use crate::permissions::Permissions;

/// What a `PATCH /roles/{id}` changes; a `None` field is left as it is.
#[derive(Debug, Default, Clone, Copy)]
pub struct RoleChanges<'a> {
    pub name: Option<&'a str>,
    pub permissions: Option<Permissions>,
    pub mentionable: Option<bool>,
    pub hoist: Option<bool>,
    /// A palette index already checked against `ROLE_COLOR_COUNT`.
    pub color: Option<i64>,
}

impl RoleChanges<'_> {
    pub fn is_empty(&self) -> bool {
        self.name.is_none()
            && self.permissions.is_none()
            && self.mentionable.is_none()
            && self.hoist.is_none()
            && self.color.is_none()
    }
}

impl Store {
    /// Updates whichever of a role's fields [`RoleChanges`] names. `Ok(None)` if the role does not
    /// exist, and a no-op call (every field `None`) is still an existence
    /// check rather than an error.
    ///
    /// Whether the requested permissions are something the caller may grant
    /// is checked by `http::roles` before this runs, since that needs the
    /// caller's own effective permissions; this only guards the structural
    /// invariant, rolling back if the update would leave the deployment with
    /// no administrator.
    ///
    /// That guard runs whenever permissions were touched at all, rather than
    /// trying to detect whether the ADMINISTRATOR bit specifically moved. Only
    /// a permissions change can remove an administrator, and checking the
    /// broader condition stays correct even when the bit arrives folded into a
    /// larger change.
    ///
    /// Built with [`QueryBuilder`] rather than one `match` arm per field
    /// combination: five optional fields would be thirty-two arms, and a sixth
    /// field would double that again.
    pub async fn update_role(
        &self,
        role_id: RoleId,
        changes: RoleChanges<'_>,
    ) -> Result<Option<Role>, RoleGuardError> {
        let RoleChanges {
            name,
            permissions,
            mentionable,
            hoist,
            color,
        } = changes;
        let mut tx = self.begin_write().await?;

        let affected: u64 = if changes.is_empty() {
            let exists = sqlx::query_scalar!(
                r#"SELECT 1 AS "one!: i64" FROM roles WHERE id = ?"#,
                role_id
            )
            .fetch_optional(&mut *tx)
            .await?;
            u64::from(exists.is_some())
        } else {
            let mut builder = QueryBuilder::new("UPDATE roles SET ");
            let mut first = true;
            if let Some(name) = name {
                builder.push("name = ").push_bind(name.to_owned());
                first = false;
            }
            if let Some(perms) = permissions {
                if !first {
                    builder.push(", ");
                }
                builder.push("permissions = ").push_bind(perms.bits());
                first = false;
            }
            if let Some(mentionable) = mentionable {
                if !first {
                    builder.push(", ");
                }
                builder
                    .push("mentionable = ")
                    .push_bind(i64::from(mentionable));
                first = false;
            }
            if let Some(hoist) = hoist {
                if !first {
                    builder.push(", ");
                }
                builder.push("hoist = ").push_bind(i64::from(hoist));
                first = false;
            }
            if let Some(color) = color {
                if !first {
                    builder.push(", ");
                }
                builder.push("color = ").push_bind(color);
            }
            builder.push(" WHERE id = ").push_bind(role_id);
            builder.build().execute(&mut *tx).await?.rows_affected()
        };
        if affected == 0 {
            return Ok(None);
        }

        // Guarded on any permissions change; see the note on this function.
        if permissions.is_some() && administrator_count(&mut tx).await? == 0 {
            return Err(RoleGuardError::LastAdministrator);
        }
        tx.commit().await?;
        Ok(self.role(role_id).await?)
    }
}
