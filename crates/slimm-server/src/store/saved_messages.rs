// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Messages one person kept for themselves: the private counterpart to
//! [`super::pins`].
//!
//! See `migrations/0060_saved_messages.sql` for why this is its own table
//! rather than a flag on a pin.
//!
//! Saving is idempotent and unsaving is a no-op on something not saved, so a
//! client that retries an uncertain request never has to reason about which
//! of the two it is - the same stance `pin_message` takes.

use anyhow::Result;

use super::{Message, Store, now_ms};
use crate::ids::{ChannelId, MessageId, Seq, UserId};

/// Most messages one account may keep at once.
///
/// A ceiling at the write rather than a page at the read, the same call
/// [`super::pins::MAX_PINS_PER_CHANNEL`] makes and for the same reason: it
/// keeps the set small enough that a reader can have all of it, instead of
/// making every reader page through something one person can grow without
/// limit. Without it `GET /saved` had no bound at all - and past SQLite's
/// `SQLITE_MAX_VARIABLE_NUMBER` the enrich batch stops preparing its
/// statements rather than merely slowing down.
///
/// Higher than the pin ceiling because this is one person's whole keep-list
/// across every channel rather than one channel's highlights, and still far
/// enough under [`super::MAX_IDS_PER_QUERY`] that the batched reads behind
/// the list never need to chunk.
pub const MAX_SAVED_MESSAGES: i64 = 500;

/// Why a save was refused.
#[derive(Debug)]
pub enum SaveError {
    /// No live message at that id.
    UnknownMessage,
    /// The caller already holds [`MAX_SAVED_MESSAGES`] saves.
    TooMany,
    Internal(anyhow::Error),
}

impl From<sqlx::Error> for SaveError {
    fn from(err: sqlx::Error) -> Self {
        SaveError::Internal(err.into())
    }
}

impl From<anyhow::Error> for SaveError {
    fn from(err: anyhow::Error) -> Self {
        SaveError::Internal(err)
    }
}

/// One entry in somebody's saved list: the message, and when they kept it.
#[derive(Debug, Clone)]
pub struct SavedMessage {
    pub message: Message,
    /// When it was saved, which is what the list is ordered by - not the
    /// message's own `created_at`, since keeping an old message should put
    /// it at the top of your list rather than the bottom.
    pub saved_at: i64,
}

impl Store {
    /// Saves [message_id] for [user_id]. Idempotent: saving something already
    /// saved leaves the original `saved_at` alone rather than moving it to
    /// the top, so a double-tap cannot silently reorder somebody's list.
    ///
    /// Refuses with [`SaveError::UnknownMessage`] if there is no live message
    /// at that id, and [`SaveError::TooMany`] at the ceiling. Authorizing the
    /// read is the caller's job; this does not check permissions.
    ///
    /// The count is taken inside the same write transaction as the insert, so
    /// two saves racing at the ceiling cannot both pass it.
    pub async fn save_message(
        &self,
        user_id: UserId,
        message_id: MessageId,
    ) -> std::result::Result<(), SaveError> {
        let mut tx = self.begin_write().await?;
        let live = sqlx::query_scalar!(
            r#"SELECT 1 AS "hit!: i64" FROM messages
               WHERE id = ? AND deleted_at IS NULL"#,
            message_id
        )
        .fetch_optional(&mut *tx)
        .await?;
        if live.is_none() {
            tx.commit().await?;
            return Err(SaveError::UnknownMessage);
        }
        // Counted only for a save that would add a row, so somebody at the ceiling can still re-save what they hold.
        let held = sqlx::query_scalar!(
            r#"SELECT COUNT(*) AS "n!: i64" FROM saved_messages s
               JOIN messages m ON m.id = s.message_id AND m.deleted_at IS NULL
               WHERE s.user_id = ?"#,
            user_id
        )
        .fetch_one(&mut *tx)
        .await?;
        let already = sqlx::query_scalar!(
            r#"SELECT 1 AS "hit!: i64" FROM saved_messages
               WHERE user_id = ? AND message_id = ?"#,
            user_id,
            message_id
        )
        .fetch_optional(&mut *tx)
        .await?
        .is_some();
        if !already && held >= MAX_SAVED_MESSAGES {
            tx.commit().await?;
            return Err(SaveError::TooMany);
        }
        let now = now_ms();
        sqlx::query!(
            "INSERT OR IGNORE INTO saved_messages (user_id, message_id, saved_at)
             VALUES (?, ?, ?)",
            user_id,
            message_id,
            now
        )
        .execute(&mut *tx)
        .await?;
        tx.commit().await?;
        Ok(())
    }

    /// Removes a save. A no-op on something that was never saved, so this
    /// answers nothing: there is no failure a caller could act on.
    pub async fn unsave_message(&self, user_id: UserId, message_id: MessageId) -> Result<()> {
        sqlx::query!(
            "DELETE FROM saved_messages WHERE user_id = ? AND message_id = ?",
            user_id,
            message_id
        )
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// One person's saved messages, newest save first.
    ///
    /// Returns every live save without filtering by what the reader can
    /// currently see, because this cannot: a saved list spans channels, and
    /// permissions are per channel. The caller has to drop the entries whose
    /// channel the reader can no longer view - access can be revoked long
    /// after something is saved, and a private list is not a licence to keep
    /// reading a channel you were removed from. [`Store::permissions_in_channels`]
    /// answers that for a whole page at once; `http::saved_messages` does it
    /// there rather than here so this stays one query.
    pub async fn list_saved_messages(&self, user_id: UserId) -> Result<Vec<SavedMessage>> {
        let rows = sqlx::query!(
            r#"SELECT s.saved_at AS "saved_at!: i64",
                      m.id AS "id!: MessageId", m.channel_id AS "channel_id!: ChannelId",
                      m.author_id AS "author_id: UserId",
                      u.display_name AS "author_display_name?: String",
                      m.seq AS "seq!: Seq", m.content AS "content!",
                      m.created_at AS "created_at!", m.edited_at,
                      m.reply_to_id AS "reply_to_id: MessageId"
               FROM saved_messages s
               JOIN messages m ON m.id = s.message_id
               LEFT JOIN users u ON u.id = m.author_id AND u.deleted_at IS NULL
               WHERE s.user_id = ? AND m.deleted_at IS NULL
               ORDER BY s.saved_at DESC"#,
            user_id
        )
        .fetch_all(&self.pool)
        .await?;

        Ok(rows
            .into_iter()
            .map(|r| SavedMessage {
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
                saved_at: r.saved_at,
            })
            .collect())
    }
}
