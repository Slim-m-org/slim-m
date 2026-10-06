// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Role and overwrite persistence, and the effective-permission read path.
//!
//! The pure precedence logic lives in [`crate::permissions`]; this module loads
//! a user's roles and a channel's overwrites and feeds them to the evaluator.

use sqlx::SqliteExecutor;
use uuid::Uuid;

use super::Store;
use crate::ids::{ChannelId, RoleId, UserId};
use crate::permissions::{Overwrite, Permissions, evaluate};

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

/// A user's roles, resolved once and reused by both permission read paths.
pub(super) struct RoleContext {
    pub(super) everyone_id: Option<Uuid>,
    pub(super) everyone_perms: Permissions,
    pub(super) role_perms: Vec<Permissions>,
    pub(super) role_ids: Vec<Uuid>,
}

impl RoleContext {
    /// The context of a principal that holds nothing, not even `@everyone`.
    pub(super) fn none() -> Self {
        Self {
            everyone_id: None,
            everyone_perms: Permissions::NONE,
            role_perms: Vec::new(),
            role_ids: Vec::new(),
        }
    }

    /// Sorts `overwrites` into the tiers `user_id` is subject to and runs the
    /// pure evaluator, so every read path buckets overwrites the same way.
    pub(super) fn evaluate_for(
        &self,
        user_id: UserId,
        overwrites: &[ChannelOverwrite],
    ) -> Evaluated {
        let mut everyone = None;
        let mut roles = Vec::new();
        let mut member = None;
        for row in overwrites {
            let overwrite = Overwrite {
                allow: row.allow,
                deny: row.deny,
            };
            match row.target_type.as_str() {
                "role" if Some(row.target_id) == self.everyone_id => everyone = Some(overwrite),
                "role" if self.role_ids.contains(&row.target_id) => roles.push(overwrite),
                "member" if row.target_id == user_id.0 => member = Some(overwrite),
                _ => {}
            }
        }
        Evaluated {
            permissions: evaluate(
                self.everyone_perms,
                &self.role_perms,
                everyone,
                &roles,
                member,
            ),
            everyone_overwrite: everyone,
        }
    }
}

/// What [`RoleContext::evaluate_for`] decided, plus the `@everyone` tier it
/// isolated on the way, which `restricted` is answered from.
pub(super) struct Evaluated {
    pub(super) permissions: Permissions,
    pub(super) everyone_overwrite: Option<Overwrite>,
}

impl Store {
    /// Grants a role to a member. Idempotent.
    pub async fn assign_role(&self, user_id: UserId, role_id: RoleId) -> anyhow::Result<bool> {
        let inserted = sqlx::query!(
            "INSERT OR IGNORE INTO member_roles (user_id, role_id) VALUES (?, ?)",
            user_id,
            role_id
        )
        .execute(&self.pool)
        .await?
        .rows_affected();
        Ok(inserted > 0)
    }

    /// Sets (or replaces) a channel overwrite for a role.
    pub async fn set_role_overwrite(
        &self,
        channel_id: ChannelId,
        role_id: RoleId,
        allow: Permissions,
        deny: Permissions,
    ) -> anyhow::Result<()> {
        set_overwrite(&self.pool, channel_id, "role", role_id.0, allow, deny).await
    }

    /// Sets (or replaces) a channel overwrite for a single member.
    pub async fn set_member_overwrite(
        &self,
        channel_id: ChannelId,
        user_id: UserId,
        allow: Permissions,
        deny: Permissions,
    ) -> anyhow::Result<()> {
        set_overwrite(&self.pool, channel_id, "member", user_id.0, allow, deny).await
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

    /// Clears a channel's role overwrite. Idempotent: clearing one that is
    /// not set still succeeds, the same as removing a reaction that is not
    /// there does.
    pub async fn delete_role_overwrite(
        &self,
        channel_id: ChannelId,
        role_id: RoleId,
    ) -> anyhow::Result<()> {
        self.delete_overwrite(channel_id, "role", role_id.0).await
    }

    /// Clears a channel's member overwrite. Idempotent, the same way.
    pub async fn delete_member_overwrite(
        &self,
        channel_id: ChannelId,
        user_id: UserId,
    ) -> anyhow::Result<()> {
        self.delete_overwrite(channel_id, "member", user_id.0).await
    }

    async fn delete_overwrite(
        &self,
        channel_id: ChannelId,
        target_type: &str,
        target_id: Uuid,
    ) -> anyhow::Result<()> {
        sqlx::query!(
            "DELETE FROM channel_overwrites
             WHERE channel_id = ? AND target_type = ? AND target_id = ?",
            channel_id,
            target_type,
            target_id
        )
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// The user's guild-level permissions, ignoring any channel. Applies the
    /// `@everyone` base, the role union, and the administrator bypass, then
    /// subtracts any timeout in force.
    pub async fn base_permissions(&self, user_id: UserId) -> anyhow::Result<Permissions> {
        Ok(self
            .granted_base_permissions(user_id)
            .await?
            .remove(self.timeout_deny(user_id).await?))
    }

    /// [`Self::base_permissions`] before the timeout subtraction: what this
    /// member's roles grant them, which is what a moderation check has to
    /// compare against so that timing somebody out cannot itself be what
    /// makes them look junior enough to time out again.
    pub async fn granted_base_permissions(&self, user_id: UserId) -> anyhow::Result<Permissions> {
        let roles = self.load_roles(user_id).await?;
        Ok(evaluate(
            roles.everyone_perms,
            &roles.role_perms,
            None,
            &[],
            None,
        ))
    }

    /// The user's effective permissions in a specific channel, applying the base
    /// then the channel overwrites in precedence order.
    ///
    /// A channel that does not exist grants nothing. Without that, a probe for
    /// a fabricated channel id would inherit the base `@everyone` permissions
    /// (it has no overwrites) and be distinguishable from a real channel the
    /// caller may not view, which would leak channel existence.
    ///
    /// A direct-message channel does not run through the role and overwrite
    /// model at all: see [`Store::dm_permissions`] for why, and specifically
    /// why that has to hold even against ADMINISTRATOR, which the evaluator
    /// bypasses for every other channel on purpose.
    pub async fn permissions_in_channel(
        &self,
        user_id: UserId,
        channel_id: ChannelId,
    ) -> anyhow::Result<Permissions> {
        Ok(self
            .granted_in_channel(user_id, channel_id)
            .await?
            .remove(self.timeout_deny(user_id).await?))
    }

    /// [`Self::permissions_in_channel`] before the timeout subtraction, for a
    /// caller that needs the unmasked grant itself - the per-channel sibling
    /// of [`Self::granted_base_permissions`], and for the same reason: an
    /// actor-versus-target escalation check has to compare what a target's
    /// roles and overwrites grant them, not what a timeout already in force
    /// has left them with.
    pub async fn granted_permissions_in_channel(
        &self,
        user_id: UserId,
        channel_id: ChannelId,
    ) -> anyhow::Result<Permissions> {
        self.granted_in_channel(user_id, channel_id).await
    }

    /// [`Self::permissions_in_channel`] before the timeout subtraction.
    ///
    /// Split out rather than masking inline so that both the role path and
    /// the direct-message early return are covered by construction: a mask
    /// written after the `evaluate` call would have silently spared DMs,
    /// which is the one channel kind where being timed out matters most to
    /// get right, since nobody else is there to notice it did not apply.
    async fn granted_in_channel(
        &self,
        user_id: UserId,
        channel_id: ChannelId,
    ) -> anyhow::Result<Permissions> {
        // A nonexistent channel grants nothing; see the note on this function.
        let Some(channel) = self.channel(channel_id).await? else {
            return Ok(Permissions::NONE);
        };
        self.evaluate_channel_permissions(user_id, channel).await
    }

    /// Whether `user_id` held VIEW_CHANNEL in `channel_id` immediately before
    /// it was soft-deleted. [`Self::channel`] excludes a deleted row, so the
    /// ordinary check always answers "no channel" once this fires; a delete
    /// leaves roles and overwrites untouched, so evaluating them against the
    /// pre-delete row is exact, not a snapshot. Never called for a DM:
    /// `http::channels::delete` refuses to delete one.
    pub async fn viewed_channel_before_delete(
        &self,
        user_id: UserId,
        channel_id: ChannelId,
    ) -> anyhow::Result<bool> {
        let Some(channel) = self.channel_including_deleted(channel_id).await? else {
            return Ok(false);
        };
        Ok(self
            .evaluate_channel_permissions(user_id, channel)
            .await?
            .contains(Permissions::VIEW_CHANNEL))
    }

    /// Resolves the channel a permission check against `channel` should
    /// actually run: itself, unless `channel` is a thread, in which case its
    /// overwrites and kind are never consulted at all - it delegates
    /// entirely to the channel its parent message lives in, "a thread
    /// inherits the parent channel's permissions" per
    /// docs/decisions/0005-threads.md. `None` means that parent no longer
    /// resolves to a live channel, so the caller should deny rather than fall
    /// back to the thread's own (nonexistent) overwrite bucket.
    pub(super) async fn permission_channel(
        &self,
        channel: super::Channel,
    ) -> anyhow::Result<Option<super::Channel>> {
        let Some(parent_message_id) = channel.parent_message_id else {
            return Ok(Some(channel));
        };
        let parent_channel_id = sqlx::query_scalar!(
            r#"SELECT channel_id AS "channel_id!: ChannelId" FROM messages WHERE id = ?"#,
            parent_message_id
        )
        .fetch_optional(&self.pool)
        .await?;
        match parent_channel_id {
            Some(parent_channel_id) => self.channel(parent_channel_id).await,
            None => Ok(None),
        }
    }

    /// The shared body of [`Self::granted_in_channel`] and
    /// [`Self::viewed_channel_before_delete`] once a channel row is already in
    /// hand, whether or not it is still live, so the overwrite-precedence
    /// bucketing exists once here rather than a fourth copy alongside the two
    /// `tests/permissions.rs` already tracks in `permissions_batch.rs`.
    async fn evaluate_channel_permissions(
        &self,
        user_id: UserId,
        channel: super::Channel,
    ) -> anyhow::Result<Permissions> {
        // A thread never has overwrites of its own; see `permission_channel`.
        let Some(channel) = self.permission_channel(channel).await? else {
            return Ok(Permissions::NONE);
        };
        let channel_id = channel.id;
        // DMs skip the role and overwrite model; see `granted_in_channel`'s note.
        if channel.kind == super::dms::DM_CHANNEL_KIND {
            return self.dm_permissions(user_id, channel_id).await;
        }

        let roles = self.load_roles(user_id).await?;
        let overwrites = self.channel_overwrites(channel_id).await?;
        Ok(roles.evaluate_for(user_id, &overwrites).permissions)
    }

    /// Whether the user holds every bit in `needed` in this channel.
    pub async fn has_permission(
        &self,
        user_id: UserId,
        channel_id: ChannelId,
        needed: Permissions,
    ) -> anyhow::Result<bool> {
        Ok(self
            .permissions_in_channel(user_id, channel_id)
            .await?
            .contains(needed))
    }

    /// A webhook's principal answers with an empty context, checked and
    /// returned before either query below ever runs: a webhook holds no
    /// roles at all, not even `@everyone`'s base grant, so an `@everyone`
    /// role that happens to carry a broad bit (ADMINISTRATOR,
    /// MENTION_EVERYONE) can never reach it by accident. Every
    /// base-permission check in this crate goes through this function, so
    /// this one guard is the whole of that enforcement. See
    /// `docs/decisions/0030-incoming-webhooks.md`.
    pub(super) async fn load_roles(&self, user_id: UserId) -> anyhow::Result<RoleContext> {
        // Checked first; see this function's own doc comment.
        let is_webhook = sqlx::query_scalar!(
            r#"SELECT is_webhook AS "is_webhook!: i64" FROM users WHERE id = ?"#,
            user_id
        )
        .fetch_optional(&self.pool)
        .await?
        .unwrap_or(0);
        if is_webhook != 0 {
            return Ok(RoleContext::none());
        }

        let (everyone_id, everyone_perms) = self.everyone_role().await?;

        let rows = sqlx::query!(
            r#"SELECT r.id AS "id!: RoleId", r.permissions AS "permissions!: Permissions"
               FROM roles r
               JOIN member_roles mr ON mr.role_id = r.id
               WHERE mr.user_id = ? AND r.is_everyone = 0"#,
            user_id
        )
        .fetch_all(&self.pool)
        .await?;

        let role_perms = rows.iter().map(|r| r.permissions).collect();
        let role_ids = rows.iter().map(|r| r.id.0).collect();

        Ok(RoleContext {
            everyone_id,
            everyone_perms,
            role_perms,
            role_ids,
        })
    }
}

impl Store {
    /// The `@everyone` role's id and base permissions; at most one such role
    /// exists (a partial unique index enforces it), so `LIMIT 1` is
    /// deterministic. `(None, NONE)` before the deployment bootstraps.
    pub(super) async fn everyone_role(&self) -> anyhow::Result<(Option<Uuid>, Permissions)> {
        let everyone = sqlx::query!(
            r#"SELECT id AS "id!: RoleId", permissions AS "permissions!: Permissions"
               FROM roles WHERE is_everyone = 1 LIMIT 1"#
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(match everyone {
            Some(row) => (Some(row.id.0), row.permissions),
            None => (None, Permissions::NONE),
        })
    }
}

/// Sets (or replaces) one channel overwrite, over any executor - the pool
/// for [`Store::set_role_overwrite`] and [`Store::set_member_overwrite`], or
/// an open transaction for a write that must land atomically with something
/// else, such as the private-channel overwrites
/// [`super::channel_create::Store::create_channel_with_id`] writes alongside the
/// channel row itself.
pub(super) async fn set_overwrite<'e, E>(
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
/// [`super::channel_create::Store::create_channel_with_id`] treats that as a
/// refusal rather than silently creating a "private" channel with no deny in
/// place to make it private.
pub(super) async fn everyone_role_id<'e, E>(executor: E) -> anyhow::Result<Option<Uuid>>
where
    E: SqliteExecutor<'e>,
{
    let row =
        sqlx::query!(r#"SELECT id AS "id!: RoleId" FROM roles WHERE is_everyone = 1 LIMIT 1"#)
            .fetch_optional(executor)
            .await?;
    Ok(row.map(|r| r.id.0))
}
