// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Full-text search over messages, split out of [`super::messages`] when that
//! file crossed the 500-line hard ceiling.
//!
//! Its own file rather than a section of that one because it is the only
//! read here with a failure mode of its own: FTS5 has no separate parse step
//! sqlx can check ahead of time, so a malformed query is reported by SQLite
//! only once the statement runs, and telling that apart from a genuinely
//! empty result is what [`SearchError`] exists for.
//!
//! [`MessageSearchFilters`] is the Slack-style operator layer
//! (`http::search` parses `from:`/`in:`/`has:`/`before:`/`after:` out of the
//! raw query text): every field here is already resolved to what SQL needs,
//! so this file never re-derives a username or a channel name from a caller
//! - that ambiguity lives entirely in `http::search`.

use sqlx::{QueryBuilder, Row};

use super::{Message, Store};
use crate::ids::{ChannelId, MessageId, Seq, UserId};

/// Why a full-text search failed.
#[derive(Debug)]
pub enum SearchError {
    /// `q` is not valid FTS5 query syntax: an unterminated quote, a dangling
    /// operator, or an unknown column filter. FTS5 has no separate parse step
    /// sqlx can check ahead of time, so SQLite only reports this once the
    /// statement runs, and that is where this is caught rather than in
    /// up-front input validation.
    InvalidQuery,
    Internal(anyhow::Error),
}

impl From<sqlx::Error> for SearchError {
    fn from(err: sqlx::Error) -> Self {
        if let sqlx::Error::Database(ref db_err) = err {
            let message = db_err.message();
            if message.contains("fts5")
                || message.contains("unterminated string")
                || message.contains("no such column")
            {
                return SearchError::InvalidQuery;
            }
        }
        SearchError::Internal(err.into())
    }
}

/// The structured half of an advanced search, already resolved to SQL-ready
/// values by `http::search`: a username to compare exactly (live usernames are
/// unique case-insensitively since migration 0095), and
/// two cheap content/existence predicates. `channel_ids` is not here - it is
/// [`Store::search_messages`]'s own parameter, since which channels are in
/// scope is answered once, before this struct is built, and an `in:` that
/// resolved to nothing is handled by the caller returning empty without
/// reaching this file at all.
#[derive(Debug, Default)]
pub struct MessageSearchFilters {
    pub author_username: Option<String>,
    pub has_attachment: bool,
    /// A message whose content contains what looks like a URL. This is a
    /// plain, case-sensitive `LIKE` over `content` rather than a real link
    /// extractor - cheap, no index needed, and precise enough for a filter
    /// rather than a validator.
    pub has_link: bool,
    /// Inclusive: `created_at >= after_ms`.
    pub after_ms: Option<i64>,
    /// Exclusive: `created_at < before_ms`, so a whole calendar day named by
    /// `before:` is excluded rather than half-included at its own midnight.
    pub before_ms: Option<i64>,
}

impl Store {
    /// Every live, non-DM channel named exactly `name`. Plural because
    /// nothing in this schema enforces a unique channel name (see
    /// `store/channels.rs`'s own doc comment), so an `in:` operator may
    /// legitimately resolve to more than one channel; the caller checks
    /// `VIEW_CHANNEL` on each and keeps only what the searcher may actually
    /// read.
    ///
    /// A thread and a DM both always carry an empty `name`, so neither can
    /// ever match here; `kind != 'dm'` is still explicit rather than relying
    /// on that, the same defensive shape `Store::list_channels` uses.
    pub async fn search_channel_ids_by_name(&self, name: &str) -> anyhow::Result<Vec<ChannelId>> {
        let ids = sqlx::query_scalar!(
            r#"SELECT id AS "id!: ChannelId" FROM channels
               WHERE name = ? AND kind != 'dm' AND deleted_at IS NULL"#,
            name
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(ids)
    }

    /// Full-text searches live messages across `channel_ids`, newest match
    /// first by `created_at` (server-assigned at insert), with `seq` as the
    /// tiebreak. Ordering by wall-clock time rather than `seq` matters once
    /// `channel_ids` spans more than one channel: `seq` is per-channel, so
    /// ordering a cross-channel result by it would rank a chatty channel's old
    /// message above a quiet channel's newer one. Within a single channel the
    /// two orders are identical, since a later insert takes both a higher `seq`
    /// and a `created_at` no earlier than the row before it.
    ///
    /// The `before_seq` cursor is a per-channel keyset like
    /// [`Store::list_messages`], correct for the single-channel search panel.
    /// The command palette's cross-channel search fetches a single page and
    /// passes no cursor; paginating a cross-channel result would need a
    /// `created_at` keyset, not this per-channel `seq` one.
    ///
    /// `query` reaches FTS5 close to as-is, so a caller may use its mini query
    /// language (`AND`/`OR`/`NOT`, `"phrase"`, a trailing `*` prefix). That is
    /// safe against leaking another channel: the index has exactly one column
    /// (`content`), so a query string has no other column to pivot to, and
    /// the channel and `deleted_at` restriction below are ordinary SQL
    /// predicates the query text can never reach - never part of the `MATCH`
    /// expression itself, so nothing in `query` can widen or redirect them.
    /// `None` means an advanced search with no free text at all: every
    /// operator in `filters` still applies, only the FTS5 join is skipped.
    ///
    /// The FTS index is reindexed on every `UPDATE` to `messages`, including a
    /// soft delete, and that trigger does not itself drop a deleted row (only
    /// an encrypted one is excluded); this filters `deleted_at IS NULL`
    /// explicitly rather than relying on the index to have dropped it.
    ///
    /// A malformed `query` must fail rather than come back empty, which is why
    /// the body opens with a join-free probe against the index. The real query
    /// joins to `messages` and filters by channel, and when that join has no
    /// candidate rows (an empty or brand-new channel) SQLite's planner can
    /// prove the whole result is empty without ever calling into FTS5's query
    /// parser - so a bad query would slip through as a silent empty result.
    /// The probe has nothing to join against, so FTS5 must parse `query` to
    /// answer it at all, and a bad one fails there every time regardless of
    /// how many rows exist.
    pub async fn search_messages(
        &self,
        channel_ids: &[ChannelId],
        query: Option<&str>,
        filters: &MessageSearchFilters,
        before_seq: Option<i64>,
        limit: i64,
    ) -> Result<Vec<Message>, SearchError> {
        if channel_ids.is_empty() {
            return Ok(Vec::new());
        }
        if let Some(q) = query {
            // Join-free probe so FTS5 must parse `query`; not dead work, see the doc above.
            sqlx::query_scalar!(
                r#"SELECT 1 AS "one!: i64" FROM messages_fts WHERE messages_fts MATCH ? LIMIT 1"#,
                q
            )
            .fetch_optional(&self.pool)
            .await?;
        }

        let mut builder = QueryBuilder::new(
            r#"SELECT m.id, m.channel_id, m.author_id, u.display_name AS author_display_name,
                      m.seq, m.content, m.created_at, m.edited_at, m.reply_to_id
               FROM messages m"#,
        );
        if query.is_some() {
            builder.push(" JOIN messages_fts ON messages_fts.rowid = m.fts_rowid");
        }
        builder.push(" LEFT JOIN users u ON u.id = m.author_id AND u.deleted_at IS NULL WHERE ");
        if let Some(q) = query {
            builder.push("messages_fts MATCH ");
            builder.push_bind(q.to_owned());
            builder.push(" AND ");
        }
        builder.push("m.channel_id IN (");
        {
            let mut separated = builder.separated(", ");
            for channel_id in channel_ids {
                separated.push_bind(*channel_id);
            }
        }
        builder.push(")");
        builder.push(" AND m.deleted_at IS NULL AND m.seq < ");
        builder.push_bind(before_seq.unwrap_or(i64::MAX));
        if let Some(username) = &filters.author_username {
            builder.push(" AND m.author_id = (SELECT id FROM users WHERE username = ");
            builder.push_bind(username.to_owned());
            builder.push(" AND deleted_at IS NULL)");
        }
        if filters.has_attachment {
            builder.push(
                " AND EXISTS (SELECT 1 FROM message_attachments ma WHERE ma.message_id = m.id)",
            );
        }
        if filters.has_link {
            builder.push(" AND (m.content LIKE '%http://%' OR m.content LIKE '%https://%')");
        }
        if let Some(after_ms) = filters.after_ms {
            builder.push(" AND m.created_at >= ");
            builder.push_bind(after_ms);
        }
        if let Some(before_ms) = filters.before_ms {
            builder.push(" AND m.created_at < ");
            builder.push_bind(before_ms);
        }
        builder.push(" ORDER BY m.created_at DESC, m.seq DESC LIMIT ");
        builder.push_bind(limit);

        let rows = builder.build().fetch_all(&self.pool).await?;
        let messages = rows
            .into_iter()
            .map(|row| -> Result<Message, sqlx::Error> {
                Ok(Message {
                    id: row.try_get::<MessageId, _>("id")?,
                    channel_id: row.try_get::<ChannelId, _>("channel_id")?,
                    author_id: row.try_get::<Option<UserId>, _>("author_id")?,
                    author_display_name: row.try_get::<Option<String>, _>("author_display_name")?,
                    seq: row.try_get::<Seq, _>("seq")?,
                    content: row.try_get::<String, _>("content")?,
                    created_at: row.try_get::<i64, _>("created_at")?,
                    edited_at: row.try_get::<Option<i64>, _>("edited_at")?,
                    reply_to_id: row.try_get::<Option<MessageId>, _>("reply_to_id")?,
                })
            })
            .collect::<Result<Vec<_>, sqlx::Error>>()?;
        Ok(messages)
    }
}
