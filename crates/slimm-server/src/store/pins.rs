// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Pinned messages: a per-channel highlight set, keyed by (channel, message)
//! exactly like reactions key on (message, user, emoji), so pinning an
//! already-pinned message is naturally idempotent rather than something the
//! caller has to check for.
//!
//! A pinned message's cleanup on delete is not this module's job: it is a
//! database trigger (migrations/0009_pins.sql) that fires directly off the
//! soft-delete `UPDATE`, so it runs no matter which code path deletes a
//! message and can never be missed by a future one that forgets pins exist.

use anyhow::Context;

use super::moderation_audit::{ModerationAction, ModerationAudit, record_moderation_audit};
use super::{Message, Store, now_ms};
use crate::ids::{ChannelId, MessageId, Seq, UserId};

/// How many messages may be pinned in one channel at a time.
///
/// A ceiling at the write rather than a page at the read, for the same reason
/// `MAX_DISTINCT_EMOJI_PER_MESSAGE` is: it keeps the set small enough
/// that every reader can have all of it, instead of making every reader page
/// through something a member can grow without limit. Generous against what a
/// pin is for - a channel with two hundred highlights has none.
pub const MAX_PINS_PER_CHANNEL: i64 = 200;

/// A pinned message, with the pin's own metadata alongside the message it
/// points at.
#[derive(Debug, Clone)]
pub struct PinnedMessage {
    pub message: Message,
    /// Who pinned it. Null once that account is anonymized, the same reason
    /// `Message::author_id` goes null.
    pub pinned_by: Option<UserId>,
    pub pinned_at: i64,
}

/// Why pinning a message failed.
#[derive(Debug)]
pub enum PinError {
    /// The message does not exist in this channel, or is deleted.
    UnknownMessage,
    /// The channel already holds [`MAX_PINS_PER_CHANNEL`] pins.
    TooMany,
    Internal(anyhow::Error),
}

impl From<sqlx::Error> for PinError {
    fn from(err: sqlx::Error) -> Self {
        PinError::Internal(err.into())
    }
}

impl From<anyhow::Error> for PinError {
    fn from(err: anyhow::Error) -> Self {
        PinError::Internal(err)
    }
}

impl Store {
    /// Pins a message in a channel. Idempotent: pinning an already-pinned
    /// message leaves the original pin's timestamp and pinner in place rather
    /// than moving them to whoever asked most recently, and does not count
    /// against [`MAX_PINS_PER_CHANNEL`], since it adds nothing.
    ///
    /// The existence check and the insert share a transaction that takes the
    /// write lock up front (see [`Store::begin_write`]), so a message deleted
    /// concurrently cannot slip a pin in behind the check.
    pub async fn pin_message(
        &self,
        channel_id: ChannelId,
        message_id: MessageId,
        pinned_by: UserId,
    ) -> Result<PinnedMessage, PinError> {
        let now = now_ms();
        let mut tx = self.begin_write().await?;

        let message = fetch_channel_message(&mut *tx, channel_id, message_id).await?;
        let Some(message) = message else {
            return Err(PinError::UnknownMessage);
        };

        // Counted inside the write transaction, or two concurrent pins race it.
        let already = sqlx::query_scalar!(
            r#"SELECT 1 AS "one!: i64" FROM pinned_messages
               WHERE channel_id = ? AND message_id = ?"#,
            channel_id,
            message_id
        )
        .fetch_optional(&mut *tx)
        .await?
        .is_some();
        if !already {
            let pinned = sqlx::query_scalar!(
                r#"SELECT COUNT(*) AS "n!: i64" FROM pinned_messages WHERE channel_id = ?"#,
                channel_id
            )
            .fetch_one(&mut *tx)
            .await?;
            if pinned >= MAX_PINS_PER_CHANNEL {
                return Err(PinError::TooMany);
            }
        }

        sqlx::query!(
            "INSERT OR IGNORE INTO pinned_messages (channel_id, message_id, pinned_by, pinned_at)
             VALUES (?, ?, ?, ?)",
            channel_id,
            message_id,
            pinned_by,
            now
        )
        .execute(&mut *tx)
        .await?;
        if !already {
            audit_pin(&mut tx, message.author_id, pinned_by, "pinned", now).await?;
        }

        // Read back, never trusting `now`/`pinned_by`: a concurrent first pin
        // may have won the INSERT OR IGNORE race, and the event must name it.
        let row = sqlx::query!(
            r#"SELECT pinned_by AS "pinned_by: UserId", pinned_at AS "pinned_at!"
               FROM pinned_messages WHERE channel_id = ? AND message_id = ?"#,
            channel_id,
            message_id
        )
        .fetch_one(&mut *tx)
        .await?;

        tx.commit().await?;
        Ok(PinnedMessage {
            message,
            pinned_by: row.pinned_by,
            pinned_at: row.pinned_at,
        })
    }

    /// Unpins a message. Idempotent: unpinning one that is not pinned (or
    /// never existed) succeeds, since the caller's intent - "this pin is
    /// gone" - already holds either way.
    pub async fn unpin_message(
        &self,
        channel_id: ChannelId,
        message_id: MessageId,
        unpinned_by: UserId,
    ) -> anyhow::Result<()> {
        let mut tx = self.begin_write().await?;
        let author = sqlx::query_scalar!(
            r#"SELECT author_id AS "author_id: UserId" FROM messages WHERE id = ?"#,
            message_id
        )
        .fetch_optional(&mut *tx)
        .await?
        .flatten();
        let removed = sqlx::query!(
            "DELETE FROM pinned_messages WHERE channel_id = ? AND message_id = ?",
            channel_id,
            message_id
        )
        .execute(&mut *tx)
        .await?
        .rows_affected();
        if removed > 0 {
            audit_pin(&mut tx, author, unpinned_by, "unpinned", now_ms()).await?;
        }
        tx.commit().await?;
        Ok(())
    }

    /// A channel's pinned messages, newest pin first, joined against the
    /// message and author in one query rather than one round trip per pin.
    ///
    /// The join re-asserts `m.channel_id = p.channel_id` rather than trusting
    /// the pin row's own channel. `pin_message` is the only writer today and
    /// it checks, so this changes no answer now; what it buys is that a future
    /// second writer cannot turn this read into a cross-channel content leak,
    /// which is a cheap guarantee to hold on a path that returns whole message
    /// bodies. This codebase's recurring shape is a second path appearing
    /// later and nothing revisiting the first one's assumptions.
    pub async fn list_pinned_messages(
        &self,
        channel_id: ChannelId,
    ) -> anyhow::Result<Vec<PinnedMessage>> {
        let rows = sqlx::query!(
            r#"SELECT p.pinned_by AS "pinned_by: UserId", p.pinned_at AS "pinned_at!",
                      m.id AS "id!: MessageId", m.channel_id AS "channel_id!: ChannelId",
                      m.author_id AS "author_id: UserId",
                      u.display_name AS "author_display_name?: String",
                      m.seq AS "seq!: Seq", m.content AS "content!",
                      m.created_at AS "created_at!", m.edited_at,
                      m.reply_to_id AS "reply_to_id: MessageId"
               FROM pinned_messages p
               JOIN messages m ON m.id = p.message_id AND m.channel_id = p.channel_id
               LEFT JOIN users u ON u.id = m.author_id AND u.deleted_at IS NULL
               WHERE p.channel_id = ? AND m.deleted_at IS NULL
               ORDER BY p.pinned_at DESC"#,
            channel_id
        )
        .fetch_all(&self.pool)
        .await?;

        Ok(rows
            .into_iter()
            .map(|r| PinnedMessage {
                message: Message {
                    id: r.id,
                    channel_id: r.channel_id,
                    author_id: r.author_id,
                    author_display_name: r.author_display_name,
                    seq: r.seq,
                    content: r.content,
                    created_at: r.created_at,
                    edited_at: r.edited_at,
                    reply_to_id: r.reply_to_id,
                },
                pinned_by: r.pinned_by,
                pinned_at: r.pinned_at,
            })
            .collect())
    }

    /// How many messages are pinned in a channel. Backs the channel header's
    /// pin count: a single indexed `COUNT(*)`, so the client never has to
    /// fetch every pinned message just to show "3".
    pub async fn pin_count(&self, channel_id: ChannelId) -> anyhow::Result<i64> {
        let count = sqlx::query_scalar!(
            r#"SELECT COUNT(*) AS "n!: i64" FROM pinned_messages WHERE channel_id = ?"#,
            channel_id
        )
        .fetch_one(&self.pool)
        .await?;
        Ok(count)
    }
}

/// Writes the moderation row for a pin change on someone else's message, in the change's own transaction.
async fn audit_pin(
    conn: &mut sqlx::SqliteConnection,
    author: Option<UserId>,
    actor: UserId,
    verb: &str,
    created_at: i64,
) -> Result<(), sqlx::Error> {
    let Some(author) = author.filter(|author| *author != actor) else {
        return Ok(());
    };
    record_moderation_audit(
        conn,
        ModerationAudit {
            actor_id: actor,
            subject_id: author,
            action: ModerationAction::MessagePinChanged,
            reason: Some(verb),
            until: None,
            created_at,
        },
    )
    .await
}

/// Fetches a live message, but only if it belongs to `channel_id`. A message
/// id from a different channel is treated as not found, so a pin can never
/// be created under a channel it does not actually belong to.
async fn fetch_channel_message(
    executor: impl sqlx::SqliteExecutor<'_>,
    channel_id: ChannelId,
    message_id: MessageId,
) -> anyhow::Result<Option<Message>> {
    let row = sqlx::query!(
        r#"SELECT m.id AS "id!: MessageId", m.channel_id AS "channel_id!: ChannelId",
                  m.author_id AS "author_id: UserId",
                  u.display_name AS "author_display_name?: String",
                  m.seq AS "seq!: Seq", m.content AS "content!",
                  m.created_at AS "created_at!", m.edited_at,
                  m.reply_to_id AS "reply_to_id: MessageId"
           FROM messages m
           LEFT JOIN users u ON u.id = m.author_id AND u.deleted_at IS NULL
           WHERE m.id = ? AND m.channel_id = ? AND m.deleted_at IS NULL"#,
        message_id,
        channel_id
    )
    .fetch_optional(executor)
    .await
    .context("loading a message to pin it")?;

    Ok(row.map(|r| Message {
        id: r.id,
        channel_id: r.channel_id,
        author_id: r.author_id,
        author_display_name: r.author_display_name,
        seq: r.seq,
        content: r.content,
        created_at: r.created_at,
        edited_at: r.edited_at,
        reply_to_id: r.reply_to_id,
    }))
}
