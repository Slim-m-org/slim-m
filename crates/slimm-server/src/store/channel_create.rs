// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Channel creation: the idempotent-by-id insert, its convenience
//! server-minted form, and the optional private-at-creation overwrites.
//!
//! Split out of [`super::channels`], which keeps the rest of a channel's CRUD
//! (fetch, rename, soft-delete), once the private-channel overwrite writes
//! pushed that module past the file budget.

use sqlx::SqliteExecutor;

use super::permissions::{everyone_role_id, set_overwrite};
use super::{Channel, Store, now_ms};
use crate::ids::{ChannelCategoryId, ChannelId, UserId};
use crate::permissions::Permissions;

/// Why creating a channel by id failed outright, rather than succeeding
/// fresh or as a retry.
#[derive(Debug)]
pub enum CreateChannelError {
    /// This id already names a DM or a thread, not a POST /channels-creatable
    /// channel. `channels` holds all three kinds under one id namespace, so a
    /// colliding id must never be handed back as if it were the caller's own
    /// text/voice channel - the same reason
    /// [`super::messages::SendError::IdConflict`] refuses to alias a foreign
    /// message rather than returning it.
    IdConflict,
    /// This id named a channel that has since been deleted. Not a retry: the
    /// channel is gone for every reader, so answering with it would report a
    /// success that left nothing behind.
    Deleted,
    /// `category_id` named a category that does not exist, or one that has
    /// been deleted - categories are soft-deleted, so the column's own
    /// `REFERENCES` still accepts a dead id. Refused rather than filed as
    /// uncategorised: a client asking for a specific section and silently
    /// getting a different one is worse than an error it can show, and
    /// deleting a category nulls `category_id` on its channels precisely so
    /// none is left pointing at it.
    UnknownCategory,
    /// Asked to create a private channel, but no `@everyone` role exists yet
    /// to deny VIEW_CHANNEL against. Not reachable through `POST /channels`:
    /// MANAGE_CHANNELS never holds on a deployment that has not bootstrapped
    /// one. Kept as a real refusal rather than silently skipping the deny,
    /// because a "private" channel with nothing making it private would be
    /// worse than an error.
    MissingEveryoneRole,
    Internal(anyhow::Error),
}

impl From<sqlx::Error> for CreateChannelError {
    fn from(err: sqlx::Error) -> Self {
        CreateChannelError::Internal(err.into())
    }
}

impl From<anyhow::Error> for CreateChannelError {
    fn from(err: anyhow::Error) -> Self {
        CreateChannelError::Internal(err)
    }
}

/// The outcome of a create, which is idempotent by client-supplied id and so
/// may be a retry; see [`Store::create_channel_with_id`].
#[derive(Debug, Clone)]
pub struct CreatedChannel {
    pub channel: Channel,
    /// False when this id already named a channel, so the call was a retry
    /// of a create that already succeeded. The caller publishes
    /// `ChannelCreated` only when this is true, or a retry would wake every
    /// connected client a second time for a channel they already know about.
    pub fresh: bool,
}

impl Store {
    /// Creates a channel and seeds its message and canvas sequence counters.
    /// Idempotent by `id`: a retry with the same id returns the row already
    /// stored under it rather than inserting again, the same contract
    /// [`super::messages::Store::send_message`] gives a message send.
    ///
    /// [`Store::create_channel`] is the convenience form for a caller with no
    /// client-supplied id of its own; it mints one and always sees
    /// [`CreatedChannel::fresh`] true, since a freshly generated UUIDv7 id
    /// cannot already be in use.
    ///
    /// Appended to the end of the deployment's channel order: one more than
    /// the highest position among live, non-DM, non-thread channels,
    /// computed inside this same transaction so two concurrent creates
    /// cannot both claim the last slot. A DM's or a thread's position is
    /// left at its schema default (0) and never read, since both are
    /// excluded from every position-ordered query - the same exclusion
    /// [`super::bootstrap::Store::list_channels`] and
    /// [`super::channel_order::Store::reorder_channels`] already apply.
    ///
    /// Uses [`Store::begin_write`] (`BEGIN IMMEDIATE`) rather than a deferred
    /// transaction, for the same reason [`super::messages::Store::send_message`]
    /// does: this reads the id before it writes.
    ///
    /// The id probe matches a deleted row as well as a live one: the id
    /// column is unique either way, so falling through to an INSERT would hit
    /// the unique id and map to a 500. A live match is a retry and comes back
    /// as one; a deleted match is [`CreateChannelError::Deleted`].
    ///
    /// `channels` also holds DM channels and threads (a thread is a channel
    /// with `parent_message_id` set), neither of which this route can create
    /// or return: a match is only a retry when it is the same
    /// text/voice-and-top-level shape this call itself would have inserted,
    /// otherwise it is [`CreateChannelError::IdConflict`] rather than a 500
    /// or a wrong-typed 200.
    ///
    /// `private_to` closes the window a create-then-restrict two-step leaves
    /// open: `Some(creator)` denies `@everyone` VIEW_CHANNEL and grants it to
    /// `creator` instead, both overwrites written in this same transaction as
    /// the channel row and its seq counters, so a caller can never observe a
    /// channel that exists but is not yet private. `None` creates a channel
    /// visible to `@everyone` as usual. Never consulted on a retry: the
    /// first, fresh create is the only one that can still choose visibility.
    ///
    /// `join_muted` is written by the same INSERT, for the same reason: a
    /// follow-up UPDATE would let a reader see the channel before its flag.
    /// Like `private_to`, it is ignored on a retry.
    pub async fn create_channel_with_id(
        &self,
        id: ChannelId,
        name: &str,
        kind: &str,
        category_id: Option<ChannelCategoryId>,
        private_to: Option<UserId>,
        join_muted: bool,
    ) -> Result<CreatedChannel, CreateChannelError> {
        let now = now_ms();
        let mut tx = self.begin_write().await?;

        // Probes including a deleted row; see this function's doc for why.
        if let Some(existing) = fetch_channel_by_id(&mut *tx, id).await? {
            tx.commit().await?;
            let creatable_kind = matches!(existing.kind.as_str(), "text" | "voice")
                && existing.parent_message_id.is_none();
            if !creatable_kind {
                return Err(CreateChannelError::IdConflict);
            }
            if channel_is_deleted(&self.pool, id).await? {
                return Err(CreateChannelError::Deleted);
            }
            return Ok(CreatedChannel {
                channel: existing,
                fresh: false,
            });
        }

        let position = sqlx::query_scalar!(
            r#"SELECT COALESCE(MAX(position), -1) + 1 AS "next!: i64" FROM channels
               WHERE deleted_at IS NULL AND kind != 'dm' AND parent_message_id IS NULL"#
        )
        .fetch_one(&mut *tx)
        .await?;
        // Live only, and checked by hand: categories are soft-deleted, so the column's `REFERENCES` would still accept a dead one.
        if let Some(category_id) = category_id {
            let known = sqlx::query_scalar!(
                r#"SELECT 1 AS "hit!: i64" FROM channel_categories
                   WHERE id = ? AND deleted_at IS NULL"#,
                category_id
            )
            .fetch_optional(&mut *tx)
            .await?;
            if known.is_none() {
                tx.commit().await?;
                return Err(CreateChannelError::UnknownCategory);
            }
        }

        sqlx::query!(
            "INSERT INTO channels (id, name, kind, position, created_at, category_id, join_muted) \
             VALUES (?, ?, ?, ?, ?, ?, ?)",
            id,
            name,
            kind,
            position,
            now,
            category_id,
            join_muted
        )
        .execute(&mut *tx)
        .await?;
        sqlx::query!(
            "INSERT INTO channel_seq_counters (channel_id, stream, next_seq)
             VALUES (?, 'message', 1), (?, 'canvas', 1)",
            id,
            id
        )
        .execute(&mut *tx)
        .await?;

        if let Some(creator_id) = private_to {
            let everyone_id = everyone_role_id(&mut *tx)
                .await?
                .ok_or(CreateChannelError::MissingEveryoneRole)?;
            set_overwrite(
                &mut *tx,
                id,
                "role",
                everyone_id,
                Permissions::NONE,
                Permissions::VIEW_CHANNEL,
            )
            .await?;
            set_overwrite(
                &mut *tx,
                id,
                "member",
                creator_id.0,
                Permissions::VIEW_CHANNEL,
                Permissions::NONE,
            )
            .await?;
        } else if let Some(category_id) = category_id {
            // A channel with no audience of its own takes its category's; see decision 0064.
            super::category_overwrites::copy_category_overwrites(&mut tx, id, category_id).await?;
        }

        tx.commit().await?;
        Ok(CreatedChannel {
            channel: Channel {
                id,
                name: name.to_owned(),
                kind: kind.to_owned(),
                topic: None,
                position,
                parent_message_id: None,
                // Whatever the caller filed it under; there is no default category (docs/decisions/0006).
                category_id,
                created_at: now,
                // The column default; a fresh channel has no slow mode set yet.
                slow_mode_seconds: 0,
                join_muted,
            },
            fresh: true,
        })
    }

    /// Creates a channel with a server-minted id; see
    /// [`Store::create_channel_with_id`] for the idempotent form a caller
    /// with a client-supplied id wants instead.
    ///
    /// [`CreateChannelError::IdConflict`] cannot happen here: a freshly
    /// generated UUIDv7 cannot already name a DM or a thread. Neither can
    /// [`CreateChannelError::UnknownCategory`] or
    /// [`CreateChannelError::MissingEveryoneRole`], since this form never
    /// names a category and never asks for a private channel. The only error
    /// this ever actually surfaces is `Internal`.
    pub async fn create_channel(&self, name: &str, kind: &str) -> anyhow::Result<Channel> {
        match self
            .create_channel_with_id(ChannelId::generate(), name, kind, None, None, false)
            .await
        {
            Ok(created) => Ok(created.channel),
            Err(CreateChannelError::IdConflict) => {
                anyhow::bail!("a freshly generated channel id collided with an existing row")
            }
            Err(CreateChannelError::Deleted) => {
                anyhow::bail!("a freshly generated channel id named a deleted channel")
            }
            Err(CreateChannelError::UnknownCategory) => {
                anyhow::bail!("uncategorised create reported an unknown category")
            }
            Err(CreateChannelError::MissingEveryoneRole) => {
                anyhow::bail!("a public create reported a missing everyone role")
            }
            Err(CreateChannelError::Internal(err)) => Err(err),
        }
    }
}

async fn channel_is_deleted(pool: &sqlx::SqlitePool, id: ChannelId) -> anyhow::Result<bool> {
    let deleted_at = sqlx::query_scalar!("SELECT deleted_at FROM channels WHERE id = ?", id)
        .fetch_one(pool)
        .await?;
    Ok(deleted_at.is_some())
}

/// Fetches a channel by id, live or deleted, over any executor - the pool for
/// [`super::channels::Store::channel_including_deleted`], or an open
/// transaction for the id probe inside [`Store::create_channel_with_id`].
pub(super) async fn fetch_channel_by_id<'e, E>(
    executor: E,
    id: ChannelId,
) -> anyhow::Result<Option<Channel>>
where
    E: SqliteExecutor<'e>,
{
    let row = sqlx::query!(
        r#"SELECT id AS "id!: ChannelId", name AS "name!", kind AS "kind!", topic,
                  position AS "position!: i64",
                  parent_message_id AS "parent_message_id: crate::ids::MessageId",
                  category_id AS "category_id: crate::ids::ChannelCategoryId",
                  created_at AS "created_at!",
                  slow_mode_seconds AS "slow_mode_seconds!: i64",
                  join_muted AS "join_muted!: bool"
           FROM channels WHERE id = ?"#,
        id
    )
    .fetch_optional(executor)
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
    }))
}
