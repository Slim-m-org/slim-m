// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The ceiling on a connector's principal (decision 0090): it may hold only
//! what the admin approved at install, whatever roles it is given later, and
//! nothing while its module is disabled.
//!
//! The ceiling is applied where roles are evaluated (`RoleContext::cap`) and,
//! for a direct message, which never reaches the roles, where the DM grant is
//! read. Every permission answer passes through one or the other.

use super::super::Store;
use crate::ids::UserId;
use crate::permissions::Permissions;

/// The ceiling column for a principal, in a query that has `u` as `users`.
pub(in crate::store) const CAP_COLUMN: &str = "(SELECT CASE WHEN m.enabled = 1 \
     THEN COALESCE(m.connector_permissions, 0) ELSE 0 END \
     FROM installed_modules m WHERE m.bot_user_id = u.id AND m.provider = 'connector')";

/// The ceiling a stored value stands for: none for an ordinary principal.
/// An approved ADMINISTRATOR is every bit, as the evaluator reads it.
pub(in crate::store) fn effective(stored: Option<Permissions>) -> Permissions {
    match stored {
        None => Permissions::ALL,
        Some(cap) if cap.contains(Permissions::ADMINISTRATOR) => Permissions::ALL,
        Some(cap) => cap.intersect(Permissions::ALL),
    }
}

impl Store {
    /// What `user_id` may do in a direct message: the DM grant, under the ceiling.
    pub(crate) async fn dm_permissions(
        &self,
        user_id: UserId,
        channel_id: crate::ids::ChannelId,
    ) -> anyhow::Result<Permissions> {
        let granted = self.dm_grant(user_id, channel_id).await?;
        Ok(granted.intersect(self.principal_cap(user_id).await?))
    }

    /// The most `user_id` may hold anywhere; [`Permissions::ALL`] for anyone but a connector.
    pub(in crate::store) async fn principal_cap(
        &self,
        user_id: UserId,
    ) -> anyhow::Result<Permissions> {
        let stored = sqlx::query_scalar!(
            r#"SELECT CASE WHEN m.enabled = 1 THEN COALESCE(m.connector_permissions, 0) ELSE 0 END
                      AS "cap!: Permissions"
               FROM installed_modules m
               WHERE m.bot_user_id = ? AND m.provider = 'connector'"#,
            user_id
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(effective(stored))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_a_connector_is_capped() {
        assert_eq!(effective(None), Permissions::ALL);
        assert_eq!(
            effective(Some(Permissions::SEND_MESSAGES)),
            Permissions::SEND_MESSAGES
        );
        assert_eq!(effective(Some(Permissions::NONE)), Permissions::NONE);
        assert_eq!(
            effective(Some(Permissions::ADMINISTRATOR)),
            Permissions::ALL
        );
    }
}
