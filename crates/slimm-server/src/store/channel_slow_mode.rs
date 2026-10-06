// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Per-channel slow mode: the read/write pair for `channels.slow_mode_seconds`
//! plus the one query the send path needs to enforce it. Split out of
//! `channels.rs` to keep that file under the line budget rather than
//! expanding its already-optional `update_channel` to a third field.

use super::{Channel, Store};
use crate::ids::{ChannelId, UserId};

impl Store {
    /// Sets a channel's slow-mode interval. `seconds` is caller-validated
    /// (the route enforces the settable range; the schema only guards
    /// non-negative) - this trusts it and stores it as given.
    ///
    /// Excludes a DM or a thread, the same `kind != 'dm' AND
    /// parent_message_id IS NULL` guard [`Store::update_channel`] applies to
    /// name and topic: neither exposes a setter for this, and both would
    /// otherwise silently accept one that can never be read back through any
    /// route, since a thread's messages resolve permissions through its
    /// parent rather than reading its own row.
    ///
    /// Returns `None` if the channel does not exist, was deleted, or is a DM
    /// or thread - the same "nothing matched" shape `update_channel` answers,
    /// so the caller's 404 handling is identical.
    pub async fn update_channel_slow_mode(
        &self,
        id: ChannelId,
        seconds: i64,
    ) -> anyhow::Result<Option<Channel>> {
        let affected = sqlx::query!(
            "UPDATE channels SET slow_mode_seconds = ? \
             WHERE id = ? AND deleted_at IS NULL AND kind != 'dm' \
             AND parent_message_id IS NULL",
            seconds,
            id
        )
        .execute(&self.pool)
        .await?
        .rows_affected();
        if affected == 0 {
            return Ok(None);
        }
        self.channel(id).await
    }

    /// The slow-mode interval that governs `id`, in seconds; 0 (off) for a
    /// missing or deleted channel rather than an error, since the send path
    /// that calls this has already resolved the channel through its own
    /// permission check and only wants a number to compare against.
    ///
    /// A thread has no setter and its row keeps the default of 0, so it takes
    /// its parent channel's interval, the same hop `permission_channel` makes.
    pub(crate) async fn channel_slow_mode_seconds(&self, id: ChannelId) -> anyhow::Result<i64> {
        let seconds = sqlx::query_scalar!(
            r#"SELECT COALESCE(parent.slow_mode_seconds, c.slow_mode_seconds) AS "seconds!: i64"
               FROM channels c
               LEFT JOIN messages pm ON pm.id = c.parent_message_id
               LEFT JOIN channels parent ON parent.id = pm.channel_id
                    AND parent.deleted_at IS NULL
               WHERE c.id = ? AND c.deleted_at IS NULL"#,
            id
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(seconds.unwrap_or(0))
    }

    /// When `author_id` last sent a message in `channel_id`, deleted ones included
    /// (deleting a message must not reopen the window), or `None` if they never
    /// have. Backed by `messages_author_channel_sent` (0099).
    pub(crate) async fn last_message_at(
        &self,
        channel_id: ChannelId,
        author_id: UserId,
    ) -> anyhow::Result<Option<i64>> {
        let last = sqlx::query_scalar!(
            r#"SELECT MAX(created_at) AS "created_at: i64" FROM messages
               WHERE channel_id = ? AND author_id = ?"#,
            channel_id,
            author_id
        )
        .fetch_one(&self.pool)
        .await?;
        Ok(last)
    }
}

/// Whole seconds a send must still wait, rounded up so a client that waits the reported time is
/// never refused twice, or `None` once `window_ms` has elapsed since `last_sent_at`.
pub fn slow_mode_retry_after_seconds(window_ms: i64, last_sent_at: i64, now: i64) -> Option<i64> {
    let remaining_ms = window_ms - (now - last_sent_at);
    (remaining_ms > 0).then(|| ((remaining_ms + 999) / 1000).max(1))
}

/// The in-transaction half of slow mode: reads the author's last send on the writer's own
/// connection, so concurrent sends queue behind each other rather than all reading the same one.
pub(super) async fn retry_after_in_tx(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    channel_id: ChannelId,
    author_id: UserId,
    window_ms: i64,
    now: i64,
) -> Result<Option<i64>, sqlx::Error> {
    let last = sqlx::query_scalar!(
        r#"SELECT MAX(created_at) AS "created_at: i64" FROM messages
           WHERE channel_id = ? AND author_id = ?"#,
        channel_id,
        author_id
    )
    .fetch_one(&mut **tx)
    .await?;
    Ok(last.and_then(|last| slow_mode_retry_after_seconds(window_ms, last, now)))
}
