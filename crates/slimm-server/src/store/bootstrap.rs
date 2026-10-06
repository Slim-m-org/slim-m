// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! First-run bootstrap and the channel and role management the admin surface
//! needs.
//!
//! A fresh deployment has no roles and no channels, so nobody can do anything.
//! The first account to register claims the deployment: it is granted an admin
//! role, an `@everyone` base role is seeded with the everyday permissions, and a
//! general channel is created. This is the self-hosted "first person to log in
//! becomes admin" model, and it runs exactly once because it is conditional on
//! there being no `@everyone` role yet.

use super::{Store, now_ms};
use crate::ids::{ChannelId, RoleId, UserId};
use crate::permissions::Permissions;

/// What `@everyone` gets on a fresh deployment: read and take part, but no
/// moderation or management.
const EVERYONE_DEFAULTS: Permissions = Permissions::VIEW_CHANNEL
    .union(Permissions::SEND_MESSAGES)
    .union(Permissions::ADD_REACTIONS)
    .union(Permissions::ATTACH_FILES)
    .union(Permissions::CONNECT)
    .union(Permissions::SPEAK)
    .union(Permissions::USE_CANVAS);

/// The outcome of a bootstrap attempt.
#[derive(Debug, PartialEq, Eq)]
pub enum Bootstrap {
    /// This account claimed the deployment and is now an administrator.
    Claimed,
    /// The deployment was already set up; nothing changed.
    AlreadySetUp,
}

impl Store {
    /// Claims an unclaimed deployment for `user_id`, seeding the `@everyone` and
    /// admin roles and a general channel.
    ///
    /// Registration does not call this: [`Store::register_account`] runs the
    /// same claim inside its own transaction, so an account and the claim it
    /// makes commit together. This stays for fixtures and a user that already
    /// exists. Two racing claims serialize on the `@everyone` unique index and
    /// the loser reports [`Bootstrap::AlreadySetUp`].
    pub async fn bootstrap_deployment(&self, user_id: UserId) -> anyhow::Result<Bootstrap> {
        let mut tx = self.begin_write().await?;
        let outcome = claim_in(&mut tx, user_id).await?;
        tx.commit().await?;
        Ok(outcome)
    }

    /// Whether this deployment has been claimed yet.
    pub async fn is_bootstrapped(&self) -> anyhow::Result<bool> {
        let found =
            sqlx::query_scalar!(r#"SELECT 1 AS "one!: i64" FROM roles WHERE is_everyone = 1"#)
                .fetch_optional(&self.pool)
                .await?;
        Ok(found.is_some())
    }

    /// Lists the deployment's live channels, oldest first.
    ///
    /// Excludes `dm`-kind channels: a DM is not a deployment channel anyone
    /// browses into, it is a conversation between exactly two people, listed
    /// instead by `Store::list_dm_conversations`. Filtering it out here,
    /// rather than trusting every caller of this method to do it themselves,
    /// is what keeps a DM out of the ordinary channel list even though it
    /// lives in the same table.
    ///
    /// Also excludes a thread (`parent_message_id IS NOT NULL`), for the same
    /// reason and by the same mechanism: a thread is a hidden sub-channel
    /// reached from the message it was opened on, never a rail entry - see
    /// docs/decisions/0005-threads.md.
    ///
    /// Ordered by category first, then by position within it -
    /// `channels.position` is a sort key within a category, not across the
    /// whole rail, since docs/decisions/0006-channel-categories.md made a
    /// category the thing that orders sections. An uncategorised channel
    /// (`category_id IS NULL`) sorts before every named category regardless
    /// of that category's own position, rendering as the implicit section
    /// the decision record describes.
    pub async fn list_channels(&self) -> anyhow::Result<Vec<super::Channel>> {
        let rows = sqlx::query!(
            r#"SELECT c.id AS "id!: ChannelId", c.name AS "name!", c.kind AS "kind!", c.topic,
                      c.position AS "position!: i64",
                      c.parent_message_id AS "parent_message_id: crate::ids::MessageId",
                      c.category_id AS "category_id: crate::ids::ChannelCategoryId",
                      c.created_at AS "created_at!",
                      c.slow_mode_seconds AS "slow_mode_seconds!: i64",
                      c.join_muted AS "join_muted!: bool"
               FROM channels c
               LEFT JOIN channel_categories cc ON cc.id = c.category_id
               WHERE c.deleted_at IS NULL AND c.kind != 'dm' AND c.parent_message_id IS NULL
               ORDER BY CASE WHEN c.category_id IS NULL THEN -1 ELSE cc.position END,
                        c.position, c.created_at"#
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .into_iter()
            .map(|r| super::Channel {
                id: r.id,
                name: r.name,
                kind: r.kind,
                topic: r.topic,
                position: r.position,
                parent_message_id: r.parent_message_id,
                category_id: r.category_id,
                created_at: r.created_at,
                slow_mode_seconds: r.slow_mode_seconds,
                join_muted: r.join_muted,
            })
            .collect())
    }
}

/// The claim itself, run inside a caller's write transaction so registration
/// can make it part of the same commit as the account that claims. The
/// `@everyone` insert is the first statement and its partial unique index is
/// the claim: a second claimant sees a unique violation and changes nothing.
pub(super) async fn claim_in(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    user_id: UserId,
) -> anyhow::Result<Bootstrap> {
    let now = now_ms();

    let everyone_id = RoleId::generate();
    let everyone_bits = EVERYONE_DEFAULTS.bits();
    let claim = sqlx::query!(
        "INSERT INTO roles (id, name, permissions, is_everyone, created_at)
             VALUES (?, 'everyone', ?, 1, ?)",
        everyone_id,
        everyone_bits,
        now
    )
    .execute(&mut **tx)
    .await;

    match claim {
        Ok(_) => {}
        // Someone else already claimed it; leave their setup alone.
        Err(sqlx::Error::Database(e)) if e.is_unique_violation() => {
            return Ok(Bootstrap::AlreadySetUp);
        }
        Err(e) => return Err(e.into()),
    }

    let admin_id = RoleId::generate();
    let admin_bits = Permissions::ADMINISTRATOR.bits();
    sqlx::query!(
        "INSERT INTO roles (id, name, permissions, is_everyone, position, created_at)
             VALUES (?, 'admin', ?, 0, 100, ?)",
        admin_id,
        admin_bits,
        now
    )
    .execute(&mut **tx)
    .await?;
    sqlx::query!(
        "INSERT INTO member_roles (user_id, role_id) VALUES (?, ?)",
        user_id,
        admin_id
    )
    .execute(&mut **tx)
    .await?;

    let channel_id = ChannelId::generate();
    sqlx::query!(
        "INSERT INTO channels (id, name, kind, created_at) VALUES (?, 'general', 'text', ?)",
        channel_id,
        now
    )
    .execute(&mut **tx)
    .await?;
    sqlx::query!(
        "INSERT INTO channel_seq_counters (channel_id, stream, next_seq)
             VALUES (?, 'message', 1), (?, 'canvas', 1)",
        channel_id,
        channel_id
    )
    .execute(&mut **tx)
    .await?;

    Ok(Bootstrap::Claimed)
}
