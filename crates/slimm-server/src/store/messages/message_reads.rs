// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The message read paths: list and fetch-by-id, over embedded SQLite. Split
//! out of `messages.rs` (the write paths: send, edit, delete) purely to stay
//! under the file budget; the module doc there still describes the shared
//! invariants (ordering, idempotent send, soft delete) both files rely on.

use sqlx::SqliteExecutor;

use super::super::{Message, Store};
use crate::ids::{ChannelId, MessageId, Seq, UserId};

impl Store {
    /// Lists a channel's live messages newest-first, using keyset pagination on
    /// `seq` (never OFFSET). Pass the smallest `seq` seen so far as `before_seq`
    /// to page backwards.
    pub async fn list_messages(
        &self,
        channel_id: ChannelId,
        before_seq: Option<i64>,
        limit: i64,
    ) -> anyhow::Result<Vec<Message>> {
        let before = before_seq.unwrap_or(i64::MAX);
        let rows = sqlx::query_as!(
            Message,
            r#"SELECT m.id AS "id!: MessageId", m.channel_id AS "channel_id!: ChannelId",
                      m.author_id AS "author_id: UserId",
                      u.display_name AS "author_display_name?: String",
                      m.seq AS "seq!: Seq",
                      m.content AS "content!", m.created_at AS "created_at!", m.edited_at,
                      m.reply_to_id AS "reply_to_id: MessageId"
               FROM messages m
               LEFT JOIN users u ON u.id = m.author_id AND u.deleted_at IS NULL
               WHERE m.channel_id = ? AND m.deleted_at IS NULL AND m.seq < ?
               ORDER BY m.seq DESC
               LIMIT ?"#,
            channel_id,
            before,
            limit
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    /// A page centred on `seq`, newest-first like [`Store::list_messages`]:
    /// the `limit / 2` live messages after it, then it and those before it.
    /// Deleted rows are skipped, so the page is by live count, not seq span.
    pub async fn list_messages_around(
        &self,
        channel_id: ChannelId,
        seq: i64,
        limit: i64,
    ) -> anyhow::Result<Vec<Message>> {
        let mut newer = self.list_messages_after(channel_id, seq, limit / 2).await?;
        newer.reverse();
        let older = self
            .list_messages(channel_id, seq.checked_add(1), limit - newer.len() as i64)
            .await?;
        newer.extend(older);
        Ok(newer)
    }

    /// Live messages with a `seq` strictly above `after_seq`, oldest-first.
    async fn list_messages_after(
        &self,
        channel_id: ChannelId,
        after_seq: i64,
        limit: i64,
    ) -> anyhow::Result<Vec<Message>> {
        let rows = sqlx::query_as!(
            Message,
            r#"SELECT m.id AS "id!: MessageId", m.channel_id AS "channel_id!: ChannelId",
                      m.author_id AS "author_id: UserId",
                      u.display_name AS "author_display_name?: String",
                      m.seq AS "seq!: Seq",
                      m.content AS "content!", m.created_at AS "created_at!", m.edited_at,
                      m.reply_to_id AS "reply_to_id: MessageId"
               FROM messages m
               LEFT JOIN users u ON u.id = m.author_id AND u.deleted_at IS NULL
               WHERE m.channel_id = ? AND m.deleted_at IS NULL AND m.seq > ?
               ORDER BY m.seq ASC
               LIMIT ?"#,
            channel_id,
            after_seq,
            limit
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    /// Fetches a live message by id, or `None` if it is missing or deleted.
    pub async fn message(&self, id: MessageId) -> anyhow::Result<Option<Message>> {
        fetch_message(&self.pool, id).await
    }

    /// Fetches a message by id whether or not it is deleted. A delete handler
    /// needs this rather than [`Store::message`] so it can authorize against
    /// an already-deleted row and tell "already gone" apart from "never
    /// existed here", which a `deleted_at`-filtered read cannot distinguish.
    pub async fn message_including_deleted(
        &self,
        id: MessageId,
    ) -> anyhow::Result<Option<Message>> {
        let message = sqlx::query_as!(
            Message,
            r#"SELECT m.id AS "id!: MessageId", m.channel_id AS "channel_id!: ChannelId",
                      m.author_id AS "author_id: UserId",
                      u.display_name AS "author_display_name?: String",
                      m.seq AS "seq!: Seq",
                      m.content AS "content!", m.created_at AS "created_at!", m.edited_at,
                      m.reply_to_id AS "reply_to_id: MessageId"
               FROM messages m
               LEFT JOIN users u ON u.id = m.author_id AND u.deleted_at IS NULL
               WHERE m.id = ?"#,
            id
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(message)
    }
}

/// Fetches one live message by id against any executor (pool or transaction).
/// Like [`fetch_message`] but sees a deleted row too, for the send
/// idempotency probe: a retried id must match whether or not the first send's
/// message has since been deleted.
pub(in crate::store) async fn fetch_message_including_deleted<'e, E>(
    executor: E,
    id: MessageId,
) -> anyhow::Result<Option<Message>>
where
    E: SqliteExecutor<'e>,
{
    let message = sqlx::query_as!(
        Message,
        r#"SELECT m.id AS "id!: MessageId", m.channel_id AS "channel_id!: ChannelId",
                  m.author_id AS "author_id: UserId",
                  u.display_name AS "author_display_name?: String",
                  m.seq AS "seq!: Seq",
                  m.content AS "content!", m.created_at AS "created_at!", m.edited_at,
                  m.reply_to_id AS "reply_to_id: MessageId"
           FROM messages m
           LEFT JOIN users u ON u.id = m.author_id AND u.deleted_at IS NULL
           WHERE m.id = ?"#,
        id
    )
    .fetch_optional(executor)
    .await?;
    Ok(message)
}

pub(in crate::store) async fn fetch_message<'e, E>(
    executor: E,
    id: MessageId,
) -> anyhow::Result<Option<Message>>
where
    E: SqliteExecutor<'e>,
{
    let message = sqlx::query_as!(
        Message,
        r#"SELECT m.id AS "id!: MessageId", m.channel_id AS "channel_id!: ChannelId",
                  m.author_id AS "author_id: UserId",
                  u.display_name AS "author_display_name?: String",
                  m.seq AS "seq!: Seq",
                  m.content AS "content!", m.created_at AS "created_at!", m.edited_at,
                  m.reply_to_id AS "reply_to_id: MessageId"
           FROM messages m
           LEFT JOIN users u ON u.id = m.author_id AND u.deleted_at IS NULL
           WHERE m.id = ? AND m.deleted_at IS NULL"#,
        id
    )
    .fetch_optional(executor)
    .await?;
    Ok(message)
}
