// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Channel permission overwrites and their persistence.

use sqlx::SqliteExecutor;
use uuid::Uuid;

use crate::ids::{ChannelId, RoleId, UserId};
use crate::permissions::Permissions;
use crate::store::Store;

/// One overwrite as stored on a channel: which role or member it targets, and
/// the allow/deny pair. The listing shape [`Store::channel_overwrites`]
/// returns, so an editor can read the current rules before changing one.
pub struct ChannelOverwrite {
    /// `"role"` or `"member"`.
    pub target_type: String,
    pub target_id: Uuid,
    pub allow: Permissions,
    pub deny: Permissions,
}

impl Store {
    /// Sets (or replaces) a channel overwrite for a role.
    pub async fn set_role_overwrite(
        &self,
        channel_id: ChannelId,
        role_id: RoleId,
        allow: Permissions,
        deny: Permissions,
    ) -> anyhow::Result<()> {
        set_overwrite(&self.pool, channel_id, "role", role_id.0, allow, deny).await?;
        crate::store::category_overwrites::mark_unsynced(&self.pool, channel_id).await
    }

    /// Sets (or replaces) a channel overwrite for a single member.
    pub async fn set_member_overwrite(
        &self,
        channel_id: ChannelId,
        user_id: UserId,
        allow: Permissions,
        deny: Permissions,
    ) -> anyhow::Result<()> {
        set_overwrite(&self.pool, channel_id, "member", user_id.0, allow, deny).await?;
        crate::store::category_overwrites::mark_unsynced(&self.pool, channel_id).await
    }

    /// The overwrite currently set for one target in one channel, if any.
    ///
    /// Callers need this to work out what a write would actually grant.
    /// Judging an overwrite by its new `allow` bits alone misses that removing
    /// a `deny` grants that permission just as surely as adding an `allow`.
    pub async fn overwrite_for(
        &self,
        channel_id: ChannelId,
        target_type: &str,
        target_id: Uuid,
    ) -> anyhow::Result<Option<(Permissions, Permissions)>> {
        let row = sqlx::query!(
            r#"SELECT allow AS "allow!: i64", deny AS "deny!: i64"
               FROM channel_overwrites
               WHERE channel_id = ? AND target_type = ? AND target_id = ?"#,
            channel_id,
            target_type,
            target_id
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.map(|r| {
            (
                Permissions::from_bits(r.allow),
                Permissions::from_bits(r.deny),
            )
        }))
    }

    /// Every overwrite set on a channel, role and member alike, so an editor
    /// can see the current allow/deny pairs before changing one rather than
    /// overwriting blind. Ordered stably for a deterministic response.
    pub async fn channel_overwrites(
        &self,
        channel_id: ChannelId,
    ) -> anyhow::Result<Vec<ChannelOverwrite>> {
        let rows = sqlx::query!(
            r#"SELECT target_type AS "target_type!",
                      target_id AS "target_id!: Uuid",
                      allow AS "allow!: Permissions",
                      deny AS "deny!: Permissions"
               FROM channel_overwrites
               WHERE channel_id = ?
               ORDER BY target_type, target_id"#,
            channel_id
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .into_iter()
            .map(|r| ChannelOverwrite {
                target_type: r.target_type,
                target_id: r.target_id,
                allow: r.allow,
                deny: r.deny,
            })
            .collect())
    }
}

/// Sets (or replaces) one channel overwrite, over any executor - the pool
/// for [`Store::set_role_overwrite`] and [`Store::set_member_overwrite`], or
/// an open transaction for a write that must land atomically with something
/// else, such as the private-channel overwrites
/// [`super::super::channel_create::Store::create_channel_with_id`] writes alongside the
/// channel row itself.
pub(in crate::store) async fn set_overwrite<'e, E>(
    executor: E,
    channel_id: ChannelId,
    target_type: &str,
    target_id: Uuid,
    allow: Permissions,
    deny: Permissions,
) -> anyhow::Result<()>
where
    E: SqliteExecutor<'e>,
{
    let allow = allow.bits();
    let deny = deny.bits();
    sqlx::query!(
        "INSERT INTO channel_overwrites (channel_id, target_type, target_id, allow, deny)
         VALUES (?, ?, ?, ?, ?)
         ON CONFLICT(channel_id, target_type, target_id)
         DO UPDATE SET allow = excluded.allow, deny = excluded.deny",
        channel_id,
        target_type,
        target_id,
        allow,
        deny
    )
    .execute(executor)
    .await?;
    Ok(())
}

/// The current `@everyone` role's id, over any executor - `None` on a
/// deployment that has not bootstrapped yet.
/// [`super::super::channel_create::Store::create_channel_with_id`] treats that as a
/// refusal rather than silently creating a "private" channel with no deny in
/// place to make it private.
pub(in crate::store) async fn everyone_role_id<'e, E>(executor: E) -> anyhow::Result<Option<Uuid>>
where
    E: SqliteExecutor<'e>,
{
    let row =
        sqlx::query!(r#"SELECT id AS "id!: RoleId" FROM roles WHERE is_everyone = 1 LIMIT 1"#)
            .fetch_optional(executor)
            .await?;
    Ok(row.map(|r| r.id.0))
}
