// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Where a forwarded message came from.
//!
//! A side table rather than columns on `messages`, and read in the batch
//! [`crate::http::message_enrich`] already runs. See
//! `migrations/0059_message_forwards.sql` for why the origin is snapshotted
//! here instead of resolved live the way a reply's parent is.
//! Deleting or ageing out the origin removes its copies; see
//! [`super::super::forward_cascade`].

use sqlx::QueryBuilder;

use super::super::Store;
use crate::ids::{ChannelId, MessageId, UserId};

/// The origin a forward is written from.
///
/// Always resolved by the server from the origin id alone, never taken from
/// the request: a client that could name its own `author_id` and `content`
/// could publish "X said Y" under any account it liked, and the forward
/// would render with that account's name and face beside it.
#[derive(Debug, Clone)]
pub struct ForwardOrigin {
    pub message_id: MessageId,
    pub channel_id: ChannelId,
    pub author_id: Option<UserId>,
    pub created_at: i64,
    pub content: String,
}

/// What a send named, and what it should actually snapshot.
///
/// The two differ whenever the named message is itself a forward: the origin
/// is then the first original, while [`ForwardSource::named_in`] stays the
/// channel the sender was actually looking at. Authorization uses the
/// latter; see [`Store::forward_source`].
#[derive(Debug, Clone)]
pub struct ForwardSource {
    /// The channel holding the message the sender named.
    pub named_in: ChannelId,
    pub origin: ForwardOrigin,
}

/// A stored forward, joined back to whatever of its origin still resolves.
///
/// The origin's channel is deliberately not joined: the client resolves the
/// name from the channel list it already holds, so a name it is not entitled
/// to never leaves the server. See [`crate::http::message_forwards`].
#[derive(Debug, Clone)]
pub struct ForwardSummary {
    pub origin: ForwardOrigin,
    /// Null once the origin's author is anonymized, exactly as on a message.
    pub author_display_name: Option<String>,
    pub author_avatar_updated_at: Option<i64>,
    /// The original was deleted or aged out; the origin fields are then blank.
    pub removed: bool,
}

impl Store {
    /// Resolves what a forward should snapshot, given the id the sender
    /// named, or `None` if there is nothing forwardable at that id.
    ///
    /// Flattens: passing on something that was itself passed on carries the
    /// first original, never the middleman. A forward's own `content` is the
    /// note its sender wrote alongside it and is usually empty, so
    /// snapshotting that would hand the next reader a blank card attributed
    /// to somebody who only relayed it.
    ///
    /// A forward whose original is gone is refused too: it has nothing left to
    /// pass on. Deleted messages are refused, which is the one place this
    /// deliberately parts company with [`Store::send_message`]'s reply
    /// target. A reply only points at its parent, so pointing at a
    /// since-deleted one stays honest; a forward copies the content, so
    /// forwarding a deleted message would republish exactly what someone
    /// removed.
    ///
    /// The caller still has to check the sender can see
    /// [`ForwardSource::named_in`] - and that channel, never the origin's.
    /// A forward already carries content somebody with access passed on, so
    /// relaying it needs no access to wherever it started; demanding that
    /// would make a forward unforwardable by exactly the people it was sent
    /// to. This resolves an id, it does not authorize one.
    pub async fn forward_source(
        &self,
        message_id: MessageId,
    ) -> anyhow::Result<Option<ForwardSource>> {
        let row = sqlx::query!(
            r#"SELECT m.channel_id AS "channel_id!: ChannelId",
                      m.author_id AS "author_id?: UserId",
                      m.created_at AS "created_at!: i64",
                      m.content AS "content!: String",
                      f.origin_message_id AS "origin_message_id?: MessageId",
                      f.origin_channel_id AS "origin_channel_id?: ChannelId",
                      f.origin_author_id AS "origin_author_id?: UserId",
                      f.origin_created_at AS "origin_created_at?: i64",
                      f.origin_content AS "origin_content?: String"
               FROM messages m
               LEFT JOIN message_forwards f ON f.message_id = m.id
               WHERE m.id = ? AND m.deleted_at IS NULL
                 AND f.origin_removed_at IS NULL"#,
            message_id
        )
        .fetch_optional(&self.pool)
        .await?;

        Ok(row.map(|r| {
            let origin = match (r.origin_message_id, r.origin_channel_id) {
                (Some(origin_id), Some(origin_channel)) => ForwardOrigin {
                    message_id: origin_id,
                    channel_id: origin_channel,
                    author_id: r.origin_author_id,
                    created_at: r.origin_created_at.unwrap_or(r.created_at),
                    content: r.origin_content.unwrap_or_default(),
                },
                _ => ForwardOrigin {
                    message_id,
                    channel_id: r.channel_id,
                    author_id: r.author_id,
                    created_at: r.created_at,
                    content: r.content,
                },
            };
            ForwardSource {
                named_in: r.channel_id,
                origin,
            }
        }))
    }

    /// Batch-loads the forward carried by each of `message_ids`, for the
    /// messages that carry one. Mirrors
    /// [`Store::attachments_for_messages`]: one query for the page rather
    /// than one per row.
    pub async fn forwards_for_messages(
        &self,
        message_ids: &[MessageId],
    ) -> anyhow::Result<Vec<(MessageId, ForwardSummary)>> {
        if message_ids.is_empty() {
            return Ok(Vec::new());
        }

        // A variable-length id list, which SQLite cannot bind as an array.
        let mut builder = QueryBuilder::new(
            "SELECT f.message_id, f.origin_message_id, f.origin_channel_id, \
                    f.origin_author_id, f.origin_created_at, f.origin_content, \
                    f.origin_removed_at IS NOT NULL AS removed, \
                    u.display_name AS author_display_name, \
                    u.avatar_updated_at AS author_avatar_updated_at \
             FROM message_forwards f \
             LEFT JOIN users u \
                    ON u.id = f.origin_author_id AND u.deleted_at IS NULL \
             WHERE f.message_id IN (",
        );
        let mut separated = builder.separated(", ");
        for id in message_ids {
            separated.push_bind(*id);
        }
        builder.push(")");

        let rows = builder.build().fetch_all(&self.pool).await?;

        use sqlx::Row;
        let mut out = Vec::with_capacity(rows.len());
        for row in rows {
            let message_id: MessageId = row.try_get("message_id")?;
            let summary = ForwardSummary {
                origin: ForwardOrigin {
                    message_id: row.try_get("origin_message_id")?,
                    channel_id: row.try_get("origin_channel_id")?,
                    author_id: row.try_get("origin_author_id")?,
                    created_at: row.try_get("origin_created_at")?,
                    content: row.try_get("origin_content")?,
                },
                author_display_name: row.try_get("author_display_name")?,
                author_avatar_updated_at: row.try_get("author_avatar_updated_at")?,
                removed: row.try_get("removed")?,
            };
            out.push((message_id, summary));
        }
        Ok(out)
    }
}

/// Records what a message was forwarded from, inside the transaction that
/// inserts the message itself - so a forward is never visible as a plain
/// message that lost its provenance.
pub(in crate::store) async fn insert_forward(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    message_id: MessageId,
    origin: &ForwardOrigin,
) -> Result<(), sqlx::Error> {
    sqlx::query!(
        r#"INSERT INTO message_forwards
               (message_id, origin_message_id, origin_channel_id,
                origin_author_id, origin_created_at, origin_content)
           VALUES (?, ?, ?, ?, ?, ?)"#,
        message_id,
        origin.message_id,
        origin.channel_id,
        origin.author_id,
        origin.created_at,
        origin.content
    )
    .execute(&mut **tx)
    .await?;
    Ok(())
}
