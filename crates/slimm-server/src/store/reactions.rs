// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Reactions: a per-(message, user, emoji) set.
//!
//! The primary key is the whole triple, so reacting twice with the same emoji
//! is naturally idempotent rather than something the handler has to check for.
//! That matters because a double tap on a slow connection is the normal case,
//! not an edge case.
//!
//! Summaries are read for a whole page of messages in one query. Doing it per
//! message would be a query per row in a fifty-message page, which is the
//! shape of problem that only shows up once a channel has real traffic.

use sqlx::QueryBuilder;

use super::Store;
use crate::ids::{MessageId, UserId};

/// Longest an emoji may be. Grapheme clusters with modifiers and zero-width
/// joiners run long (a family emoji is well over 20 bytes), so this is
/// generous, but bounded: the column is not a place to stash arbitrary text.
pub const MAX_EMOJI_BYTES: usize = 64;

/// How many distinct emoji one message may carry, across all users. Without a
/// cap a single message is an unbounded write target.
pub const MAX_DISTINCT_EMOJI_PER_MESSAGE: i64 = 40;

/// One emoji on one message, with who used it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReactionSummary {
    pub emoji: String,
    pub count: i64,
    /// Whether the user who asked reacted with this emoji. The client needs it
    /// to render the toggled state without a second request.
    pub reacted: bool,
}

/// Where the previous page of a reactor list ended: the reaction time and the
/// user, so two reactions in one millisecond still have a strict order.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ReactorCursor {
    pub created_at: i64,
    pub user_id: UserId,
}

/// Why adding a reaction failed.
#[derive(Debug)]
pub enum ReactError {
    /// The message does not exist, or is deleted.
    UnknownMessage,
    /// The emoji is empty or longer than [`MAX_EMOJI_BYTES`].
    InvalidEmoji,
    /// This message already carries [`MAX_DISTINCT_EMOJI_PER_MESSAGE`] distinct
    /// emoji and this would be another one.
    TooManyDistinctEmoji,
    Internal(anyhow::Error),
}

impl From<sqlx::Error> for ReactError {
    fn from(err: sqlx::Error) -> Self {
        ReactError::Internal(err.into())
    }
}

impl Store {
    /// Adds a reaction. Idempotent: reacting again with the same emoji leaves
    /// exactly one row and is not an error.
    pub async fn add_reaction(
        &self,
        message_id: MessageId,
        user_id: UserId,
        emoji: &str,
    ) -> Result<(), ReactError> {
        if emoji.is_empty() || emoji.len() > MAX_EMOJI_BYTES {
            return Err(ReactError::InvalidEmoji);
        }

        let now = super::now_ms();
        // Reads the message before it decides what to write, so it must hold
        // the write lock from the start; see Store::begin_write.
        let mut tx = self.begin_write().await?;

        // Inside the transaction, not before it, so a concurrent delete cannot
        // slip a reaction in behind the check.
        let exists = sqlx::query_scalar!(
            r#"SELECT 1 AS "one!: i64" FROM messages WHERE id = ? AND deleted_at IS NULL"#,
            message_id
        )
        .fetch_optional(&mut *tx)
        .await?
        .is_some();
        if !exists {
            return Err(ReactError::UnknownMessage);
        }

        // Counting only for an emoji new to this message keeps a busy message
        // with few distinct emoji cheap, and bounds the case that does grow.
        let is_new = sqlx::query_scalar!(
            r#"SELECT 1 AS "one!: i64" FROM reactions WHERE message_id = ? AND emoji = ? LIMIT 1"#,
            message_id,
            emoji
        )
        .fetch_optional(&mut *tx)
        .await?
        .is_none();
        if is_new {
            let distinct = sqlx::query_scalar!(
                r#"SELECT COUNT(DISTINCT emoji) AS "n!: i64" FROM reactions WHERE message_id = ?"#,
                message_id
            )
            .fetch_one(&mut *tx)
            .await?;
            if distinct >= MAX_DISTINCT_EMOJI_PER_MESSAGE {
                return Err(ReactError::TooManyDistinctEmoji);
            }
        }

        sqlx::query!(
            "INSERT OR IGNORE INTO reactions (message_id, user_id, emoji, created_at)
             VALUES (?, ?, ?, ?)",
            message_id,
            user_id,
            emoji,
            now
        )
        .execute(&mut *tx)
        .await?;

        tx.commit().await?;
        Ok(())
    }

    /// Removes a reaction. Removing one that was never there is not an error:
    /// the caller's intent is "this emoji of mine is gone", and it is.
    pub async fn remove_reaction(
        &self,
        message_id: MessageId,
        user_id: UserId,
        emoji: &str,
    ) -> anyhow::Result<()> {
        sqlx::query!(
            "DELETE FROM reactions WHERE message_id = ? AND user_id = ? AND emoji = ?",
            message_id,
            user_id,
            emoji
        )
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// Summaries for one message, ordered by first use so the row does not
    /// reshuffle under the reader as counts change.
    pub async fn reactions_for_message(
        &self,
        message_id: MessageId,
        viewer: UserId,
    ) -> anyhow::Result<Vec<ReactionSummary>> {
        Ok(self
            .reactions_for_messages(&[message_id], viewer)
            .await?
            .into_iter()
            .next()
            .map(|(_, summaries)| summaries)
            .unwrap_or_default())
    }

    /// Summaries for a page of messages, in one query.
    ///
    /// Returns only messages that actually have reactions, so the caller must
    /// treat a missing id as "no reactions" rather than expecting one entry per
    /// input.
    ///
    /// A reactor the `viewer` has blocked is not counted, and an emoji whose
    /// only reactors are blocked is absent rather than sitting at zero. This is
    /// the one part of blocking a client cannot do for itself: the wire carries
    /// a count and a `reacted` flag, never the reactor ids, deliberately, so
    /// there is nothing for a client-side filter to match on. Excluding them
    /// here is still the viewer's own view rather than a moderation action -
    /// the reaction is untouched for everybody else, and the reactor is never
    /// told.
    pub async fn reactions_for_messages(
        &self,
        message_ids: &[MessageId],
        viewer: UserId,
    ) -> anyhow::Result<Vec<(MessageId, Vec<ReactionSummary>)>> {
        if message_ids.is_empty() {
            return Ok(Vec::new());
        }

        // Built rather than a fixed `query!` because the id list is variable
        // length and SQLite has no array binding.
        let mut builder = QueryBuilder::new(
            "SELECT message_id, emoji, COUNT(*) AS n, \
             MAX(CASE WHEN user_id = ",
        );
        builder.push_bind(viewer);
        builder.push(
            " THEN 1 ELSE 0 END) AS reacted, MIN(created_at) AS first_at \
             FROM reactions WHERE message_id IN (",
        );
        let mut separated = builder.separated(", ");
        for id in message_ids {
            separated.push_bind(*id);
        }
        builder
            .push(") AND user_id NOT IN (SELECT blocked_id FROM user_blocks WHERE blocker_id = ");
        builder.push_bind(viewer);
        builder.push(") GROUP BY message_id, emoji ORDER BY first_at ASC");

        let rows = builder.build().fetch_all(&self.pool).await?;

        use sqlx::Row;
        let mut grouped: Vec<(MessageId, Vec<ReactionSummary>)> = Vec::new();
        for row in rows {
            let message_id: MessageId = row.try_get("message_id")?;
            let summary = ReactionSummary {
                emoji: row.try_get("emoji")?,
                count: row.try_get("n")?,
                reacted: row.try_get::<i64, _>("reacted")? == 1,
            };
            match grouped.iter_mut().find(|(id, _)| *id == message_id) {
                Some((_, list)) => list.push(summary),
                None => grouped.push((message_id, vec![summary])),
            }
        }
        Ok(grouped)
    }

    /// Every reactor of one message, with no viewer and no blocklist filter
    /// applied: grouped by emoji, each reactor paired with its own
    /// `created_at` rather than a pre-reduced `first_at`, because the old
    /// per-viewer `first_at` this replaces was always computed *after*
    /// excluding a viewer's blocked reactors - a blocked reactor's early
    /// timestamp must not be able to shift where an emoji sorts for that
    /// viewer, so the reduction has to happen per viewer, downstream of this
    /// method, not here. Rows arrive grouped by emoji (not yet ordered by any
    /// per-viewer `first_at`, since there is no single one); the caller sorts.
    ///
    /// Meant to be read once per live [`crate::hub::MessageEvent::ReactionsChanged`]
    /// rather than once per receiving connection - the N-viewers-cost-N-queries
    /// debt this method exists to close. A receiving connection turns this
    /// shared answer into its own view with [`Store::blocked_among`], read
    /// fresh against this same set of reactors rather than cached, so a block
    /// made a moment ago is never served stale.
    pub async fn reaction_reactors(
        &self,
        message_id: MessageId,
    ) -> anyhow::Result<Vec<(String, Vec<(UserId, i64)>)>> {
        use sqlx::Row;
        let rows = sqlx::query(
            "SELECT emoji, user_id, created_at FROM reactions \
             WHERE message_id = ? ORDER BY emoji ASC, created_at ASC",
        )
        .bind(message_id)
        .fetch_all(&self.pool)
        .await?;

        let mut grouped: Vec<(String, Vec<(UserId, i64)>)> = Vec::new();
        for row in rows {
            let emoji: String = row.try_get("emoji")?;
            let user_id: UserId = row.try_get("user_id")?;
            let created_at: i64 = row.try_get("created_at")?;
            match grouped.iter_mut().find(|(e, _)| *e == emoji) {
                Some((_, reactors)) => reactors.push((user_id, created_at)),
                None => grouped.push((emoji, vec![(user_id, created_at)])),
            }
        }
        Ok(grouped)
    }

    /// One page of the people who left `emoji` on a message, oldest reaction
    /// first, without a reactor the `viewer` has blocked.
    ///
    /// The block clause is the same one [`Store::reactions_for_messages`]
    /// counts with, so a viewer's list is always as long as the tally they
    /// were shown. Returns at most `limit` rows; the caller asks for one more
    /// than it will show to learn whether another page exists.
    pub async fn reaction_reactor_page(
        &self,
        message_id: MessageId,
        viewer: UserId,
        emoji: &str,
        after: Option<ReactorCursor>,
        limit: i64,
    ) -> anyhow::Result<Vec<ReactorCursor>> {
        use sqlx::Row;
        let mut builder =
            QueryBuilder::new("SELECT user_id, created_at FROM reactions WHERE message_id = ");
        builder.push_bind(message_id);
        builder.push(" AND emoji = ");
        builder.push_bind(emoji);
        builder.push(" AND user_id NOT IN (SELECT blocked_id FROM user_blocks WHERE blocker_id = ");
        builder.push_bind(viewer);
        builder.push(")");
        if let Some(cursor) = after {
            builder.push(" AND (created_at > ");
            builder.push_bind(cursor.created_at);
            builder.push(" OR (created_at = ");
            builder.push_bind(cursor.created_at);
            builder.push(" AND user_id > ");
            builder.push_bind(cursor.user_id);
            builder.push("))");
        }
        builder.push(" ORDER BY created_at ASC, user_id ASC LIMIT ");
        builder.push_bind(limit);

        let mut page = Vec::new();
        for row in builder.build().fetch_all(&self.pool).await? {
            page.push(ReactorCursor {
                user_id: row.try_get("user_id")?,
                created_at: row.try_get("created_at")?,
            });
        }
        Ok(page)
    }
}
