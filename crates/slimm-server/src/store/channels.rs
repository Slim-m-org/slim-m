// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Channel persistence: fetch, rename, and soft-delete. Creation lives in
//! [`self::channel_create`], split out once the private-channel overwrite
//! writes pushed this module past the file budget.
//!
//! Listing lives in [`super::bootstrap`] alongside the rest of the admin
//! surface it was introduced with; this module is the rest of the CRUD paths
//! for a single channel.

use self::channel_create::fetch_channel_by_id;
use super::{Channel, Store, now_ms};
use crate::ids::ChannelId;

pub(super) mod channel_create;
pub(super) mod channel_notification_prefs;
pub(super) mod channel_order;
pub(super) mod channel_restricted;
pub(super) mod channel_retention;
pub(super) mod channel_settings;
pub(crate) mod channel_slow_mode;

/// Why deleting a channel failed.
#[derive(Debug)]
pub enum DeleteChannelError {
    /// This is the deployment's last live channel. Refused rather than
    /// honoured: a deployment with zero channels has nowhere for anyone to
    /// land, the same reason bootstrap seeds a `general` channel for a fresh
    /// deployment in the first place.
    LastChannel,
    Internal(anyhow::Error),
}

impl From<sqlx::Error> for DeleteChannelError {
    fn from(err: sqlx::Error) -> Self {
        DeleteChannelError::Internal(err.into())
    }
}

impl Store {
    /// Fetches a live channel by id, or `None` if it is missing or deleted.
    pub async fn channel(&self, id: ChannelId) -> anyhow::Result<Option<Channel>> {
        let row = sqlx::query!(
            r#"SELECT id AS "id!: ChannelId", name AS "name!", kind AS "kind!", topic,
                      position AS "position!: i64",
                      parent_message_id AS "parent_message_id: crate::ids::MessageId",
                      category_id AS "category_id: crate::ids::ChannelCategoryId",
                      created_at AS "created_at!",
                      slow_mode_seconds AS "slow_mode_seconds!: i64",
                      join_muted AS "join_muted!: bool",
                      creates_rooms AS "creates_rooms!: bool",
                      user_limit AS "user_limit!: i64",
                      room_owner_id AS "room_owner_id: crate::ids::UserId",
                      room_lobby_id AS "room_lobby_id: ChannelId",
                      room_locked AS "room_locked!: bool"
               FROM channels WHERE id = ? AND deleted_at IS NULL"#,
            id
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.map(|r| Channel {
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
            room: super::ChannelRoom {
                creates_rooms: r.creates_rooms,
                user_limit: r.user_limit,
                owner_id: r.room_owner_id,
                lobby_id: r.room_lobby_id,
                locked: r.room_locked,
            },
        }))
    }

    /// Whether a channel can scope moderation to moderators of its own.
    ///
    /// A live text or voice channel can: a member holding `MANAGE_MESSAGES`
    /// there is a moderator of it, and a report about a message there is
    /// theirs to see. A DM cannot, because it has no moderators, only its
    /// pair; a deleted channel no longer can. A report about either belongs to
    /// the deployment's moderators, so this answers false and the caller falls
    /// back to the base check they already passed rather than a per-channel
    /// check that a DM or a gone channel grants to nobody.
    ///
    /// A thread resolves to the channel its parent message lives in, through
    /// [`Store::permission_channel`] - the same resolution every other
    /// permission check in this codebase already applies, rather than a
    /// second copy of it. It answered `false` unconditionally here until this
    /// was fixed, the same as a DM: a thread carries no `channel_overwrites`
    /// bucket of its own, so asking about it directly had nothing to
    /// evaluate. That let a moderator explicitly denied `MANAGE_MESSAGES` on
    /// a channel by overwrite still see, and resolve, reports about messages
    /// inside that channel's threads - the report queue's per-channel
    /// exclusion was never applied to them at all.
    pub async fn channel_scopes_moderation(&self, id: ChannelId) -> anyhow::Result<bool> {
        let Some(channel) = self.channel(id).await? else {
            return Ok(false);
        };
        let Some(channel) = self.permission_channel(channel).await? else {
            return Ok(false);
        };
        Ok(channel.kind != super::dms::DM_CHANNEL_KIND)
    }

    /// Fetches a channel by id whether or not it is deleted. The delete
    /// handler needs this rather than [`Store::channel`] to tell "never
    /// existed" (a 404) apart from "already deleted" (an idempotent no-op),
    /// which a `deleted_at`-filtered read cannot distinguish, the same
    /// reason [`Store::message_including_deleted`] exists.
    pub async fn channel_including_deleted(
        &self,
        id: ChannelId,
    ) -> anyhow::Result<Option<Channel>> {
        fetch_channel_by_id(&self.pool, id).await
    }

    /// Renames a channel and/or replaces its topic. `None` for either leaves
    /// that field untouched; `Some(None)` for `topic` clears it. Returns
    /// `None` if the channel does not exist (or was deleted, racing this
    /// call). Callers are expected to reject the case where both are `None`
    /// before reaching here (there is nothing to update), the same
    /// convention [`super::roles::update_role`] follows for its own two
    /// optional fields; this still resolves it safely as a plain existence
    /// check rather than assuming it can't happen.
    /// A DM is a channel of kind `dm` in this same table, and it is deliberately
    /// unreachable here: its only access rule is membership of the pair
    /// ([`super::dms`]), while these management routes gate on deployment-wide
    /// `MANAGE_CHANNELS`. Excluding it in SQL rather than at the call site is the
    /// same choice `list_channels` made, and for the same reason - the guard
    /// holds however many handlers end up calling this.
    pub async fn update_channel(
        &self,
        id: ChannelId,
        name: Option<&str>,
        topic: Option<Option<&str>>,
    ) -> anyhow::Result<Option<Channel>> {
        let affected = match (name, topic) {
            (Some(name), Some(topic)) => sqlx::query!(
                "UPDATE channels SET name = ?, topic = ? \
                 WHERE id = ? AND deleted_at IS NULL AND kind != 'dm' \
                 AND parent_message_id IS NULL",
                name,
                topic,
                id
            )
            .execute(&self.pool)
            .await?
            .rows_affected(),
            (Some(name), None) => sqlx::query!(
                "UPDATE channels SET name = ? \
                 WHERE id = ? AND deleted_at IS NULL AND kind != 'dm' \
                 AND parent_message_id IS NULL",
                name,
                id
            )
            .execute(&self.pool)
            .await?
            .rows_affected(),
            (None, Some(topic)) => sqlx::query!(
                "UPDATE channels SET topic = ? \
                 WHERE id = ? AND deleted_at IS NULL AND kind != 'dm' \
                 AND parent_message_id IS NULL",
                topic,
                id
            )
            .execute(&self.pool)
            .await?
            .rows_affected(),
            (None, None) => {
                let exists = sqlx::query_scalar!(
                    r#"SELECT 1 AS "one!: i64" FROM channels
                       WHERE id = ? AND deleted_at IS NULL AND kind != 'dm'
                         AND parent_message_id IS NULL"#,
                    id
                )
                .fetch_optional(&self.pool)
                .await?;
                u64::from(exists.is_some())
            }
        };
        if affected == 0 {
            return Ok(None);
        }
        self.channel(id).await
    }

    /// Soft-deletes a channel, refusing to remove the deployment's last live
    /// one. Returns whether this call performed the delete, so a retry
    /// against an already-deleted channel is idempotent rather than an error.
    ///
    /// Write-first: the single `UPDATE` both claims the row and enforces the
    /// last-channel guard in its `WHERE` clause, so two concurrent deletes of
    /// the deployment's last two channels cannot both succeed and leave zero.
    /// A separate "count, then decide, then delete" would race exactly there.
    /// Excludes `dm` channels for the reason given on [`Self::update_channel`].
    /// Note the last-channel guard counts only non-DM channels: otherwise a
    /// deployment could delete its final real channel as long as one DM existed,
    /// leaving members with nowhere to talk.
    ///
    /// The guard is also skipped entirely when the row being deleted is itself
    /// a thread. Excluding threads from the *count* was never enough: the guard
    /// still applied to the thread's own deletion, so a deployment sitting on
    /// one real channel could not delete any thread at all, having done nothing
    /// wrong. Deleting a thread cannot reduce the number of real channels, so
    /// there is nothing here for it to protect.
    ///
    /// It excludes a thread's own channels from that same count for the
    /// identical reason: a thread is never where anyone lands, and without
    /// this a deployment holding a handful of threads on its one real channel
    /// could have that channel deleted while the count still reads above one -
    /// see docs/decisions/0005-threads.md.
    pub async fn delete_channel(&self, id: ChannelId) -> Result<bool, DeleteChannelError> {
        let now = now_ms();
        let mut tx = self.begin_write().await?;

        let affected = sqlx::query!(
            "UPDATE channels SET deleted_at = ?
             WHERE id = ? AND deleted_at IS NULL AND kind != 'dm'
               AND (parent_message_id IS NOT NULL
                    OR (SELECT COUNT(*) FROM channels
                        WHERE deleted_at IS NULL AND kind != 'dm'
                          AND parent_message_id IS NULL) > 1)",
            now,
            id
        )
        .execute(&mut *tx)
        .await?
        .rows_affected();

        if affected > 0 {
            tx.commit().await?;
            return Ok(true);
        }

        // The UPDATE matched nothing: tell "already gone" (idempotent no-op)
        // apart from "still live and alone" (the last-channel guard fired).
        let still_live = sqlx::query_scalar!(
            r#"SELECT 1 AS "one!: i64" FROM channels WHERE id = ? AND deleted_at IS NULL"#,
            id
        )
        .fetch_optional(&mut *tx)
        .await?
        .is_some();
        tx.commit().await?;

        if still_live {
            Err(DeleteChannelError::LastChannel)
        } else {
            Ok(false)
        }
    }
}
