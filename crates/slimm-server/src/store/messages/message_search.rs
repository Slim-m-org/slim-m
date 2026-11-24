// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Full-text search over messages, split out of [`super`] when that
//! file crossed the 500-line hard ceiling.
//!
//! Its own file rather than a section of that one because it is the only
//! read here with a failure mode of its own: FTS5 has no separate parse step
//! sqlx can check ahead of time, so a malformed query is reported by SQLite
//! only once the statement runs, and telling that apart from a genuinely
//! empty result is what [`SearchError`] exists for.
//!
//! [`MessageSearchFilters`] is the operator layer, in its own file
//! (`message_search_filters.rs`): every field is already resolved to what SQL
//! needs, so this file never re-derives a username or a channel name.

use sqlx::{AssertSqlSafe, QueryBuilder, Row};

use super::super::voice_transcripts::TRANSCRIPT_TEXT_SHOWN;
use super::super::{Message, Store};
use super::message_search_filters::MessageSearchFilters;
use super::message_search_terms::{
    has_unsegmented, literal_fts_query, phrase, plain_words, prefix_terms_allowed, uses_fts_syntax,
};
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
    /// `before_id` names no message, so there is no position to page from;
    /// answering an empty page would read as the end of the results.
    UnknownCursor,
    Internal(anyhow::Error),
}

impl From<sqlx::Error> for SearchError {
    fn from(err: sqlx::Error) -> Self {
        if let sqlx::Error::Database(ref db_err) = err {
            let message = db_err.message();
            if FTS5_PARSE_ERRORS.iter().any(|m| message.contains(m)) {
                return SearchError::InvalidQuery;
            }
        }
        SearchError::Internal(err.into())
    }
}

/// What FTS5's query parser says about a `MATCH` it refuses; none names a SQL fault.
const FTS5_PARSE_ERRORS: [&str; 4] = [
    "fts5",
    "unterminated string",
    "no such column",
    "unknown special query",
];

/// An FTS5 expression [`Store::fts_query_for`] parsed or built from plain
/// words, so [`Store::search_messages_prepared`] runs it without probing again.
#[derive(Debug, Clone)]
pub struct FtsQuery {
    expr: String,
    unsegmented: Option<Unsegmented>,
}

/// The words of a plain query written without spaces between words, which
/// `unicode61` indexes as one token and so only a substring match can find.
#[derive(Debug, Clone)]
struct Unsegmented {
    words: Vec<String>,
    /// The query's other words, an FTS5 expression; empty when there are none.
    rest: String,
}

impl FtsQuery {
    pub fn as_str(&self) -> &str {
        &self.expr
    }

    fn syntax(expr: &str) -> Self {
        Self {
            expr: expr.to_owned(),
            unsegmented: None,
        }
    }

    fn plain(q: &str) -> Option<Self> {
        let expr = literal_fts_query(q);
        if expr.is_empty() {
            return None;
        }
        let (words, others): (Vec<&str>, Vec<&str>) =
            plain_words(q).partition(|w| has_unsegmented(w));
        let unsegmented = (!words.is_empty()).then(|| Unsegmented {
            words: words.into_iter().map(str::to_owned).collect(),
            rest: others
                .iter()
                .enumerate()
                .map(|(i, w)| phrase(w, i))
                .collect::<Vec<_>>()
                .join(" "),
        });
        Some(Self { expr, unsegmented })
    }
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

    /// Whether `id` is a message in one of `channel_ids`; a message elsewhere reads as missing.
    async fn cursor_in_scope(
        &self,
        id: MessageId,
        channel_ids: &[ChannelId],
    ) -> Result<bool, SearchError> {
        let mut builder = QueryBuilder::new("SELECT 1 FROM messages WHERE id = ");
        builder.push_bind(id);
        builder.push(" AND channel_id IN (");
        let mut separated = builder.separated(", ");
        for channel_id in channel_ids {
            separated.push_bind(*channel_id);
        }
        builder.push(")");
        let found: Option<i64> = builder
            .build_query_scalar()
            .fetch_optional(&self.pool)
            .await?;
        Ok(found.is_some())
    }

    /// The FTS5 query to run for what the user typed. Plain words become prefix
    /// phrases ([`literal_fts_query`]), so `Win` finds `Win11_24H2.iso` and
    /// `Windows`, except a one-character word, which must match whole. Text
    /// written in FTS5 syntax ([`uses_fts_syntax`]) is `q` itself when it
    /// parses, else its words, and [`SearchError::InvalidQuery`] when it has
    /// none. `None` when plain text has no word.
    pub async fn fts_query_for(&self, q: &str) -> Result<Option<FtsQuery>, SearchError> {
        let syntax_refused = uses_fts_syntax(q)
            && match self.probe_fts(q).await {
                Ok(()) => return Ok(Some(FtsQuery::syntax(q))),
                Err(SearchError::InvalidQuery) => true,
                Err(e) => return Err(e),
            };
        match (FtsQuery::plain(q), syntax_refused) {
            (Some(query), _) => Ok(Some(query)),
            (None, true) => Err(SearchError::InvalidQuery),
            (None, false) => Ok(None),
        }
    }

    /// Join-free probe so FTS5 must parse `q` against every index the search reads, so a column
    /// filter only one of them has is refused here rather than mid-search; see [`Self::search_messages`].
    /// Any plain SQLite error here is the parser's, since the statement has nothing else to fail.
    async fn probe_fts(&self, q: &str) -> Result<(), SearchError> {
        if !prefix_terms_allowed(q) {
            return Err(SearchError::InvalidQuery);
        }
        let probed = sqlx::query_scalar!(
            r#"SELECT 1 AS "one!: i64" FROM messages_fts WHERE messages_fts MATCH ? LIMIT 1"#,
            q
        )
        .fetch_optional(&self.pool)
        .await;
        let mut outcome = probe_outcome(probed);
        for table in [
            "attachment_text_fts",
            "attachment_name_fts",
            "message_extra_fts",
        ] {
            if outcome.is_err() {
                break;
            }
            let sql = format!("SELECT 1 FROM {table} WHERE {table} MATCH ? LIMIT 1");
            let probed = sqlx::query_scalar::<_, i64>(AssertSqlSafe(sql))
                .bind(q)
                .fetch_optional(&self.pool)
                .await;
            outcome = probe_outcome(probed);
        }
        outcome
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
    /// `query` is a raw FTS5 expression, so a caller may use its mini query
    /// language (`AND`/`OR`/`NOT`, `"phrase"`,
    /// a trailing `*` prefix). That is safe against leaking another channel:
    /// the index has exactly one column (`content`), so a query string has no
    /// other column to pivot to, and the channel and `deleted_at` restriction
    /// below are ordinary SQL predicates the query text can never reach -
    /// never part of the `MATCH` expression itself, so nothing in `query` can
    /// widen or redirect them.
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
        if !channel_ids.is_empty()
            && let Some(q) = query
        {
            self.probe_fts(q).await?;
        }
        let query = query.map(FtsQuery::syntax);
        self.run_message_search(channel_ids, query.as_ref(), filters, before_seq, limit)
            .await
    }

    /// [`Self::search_messages`] for a query [`Self::fts_query_for`] already
    /// parsed or built, which is why it skips the probe.
    pub async fn search_messages_prepared(
        &self,
        channel_ids: &[ChannelId],
        query: Option<&FtsQuery>,
        filters: &MessageSearchFilters,
        before_seq: Option<i64>,
        limit: i64,
    ) -> Result<Vec<Message>, SearchError> {
        self.run_message_search(channel_ids, query, filters, before_seq, limit)
            .await
    }

    async fn run_message_search(
        &self,
        channel_ids: &[ChannelId],
        query: Option<&FtsQuery>,
        filters: &MessageSearchFilters,
        before_seq: Option<i64>,
        limit: i64,
    ) -> Result<Vec<Message>, SearchError> {
        if channel_ids.is_empty() {
            return Ok(Vec::new());
        }

        if let Some(before_id) = filters.before_id
            && !self.cursor_in_scope(before_id, channel_ids).await?
        {
            return Err(SearchError::UnknownCursor);
        }

        let mut builder = QueryBuilder::new(
            r#"SELECT m.id, m.channel_id, m.author_id, u.display_name AS author_display_name,
                      m.seq, m.content, m.created_at, m.edited_at, m.reply_to_id
               FROM messages m"#,
        );
        builder.push(" LEFT JOIN users u ON u.id = m.author_id AND u.deleted_at IS NULL WHERE ");
        if let Some(query) = query {
            let q = query.as_str();
            if query.unsegmented.is_some() {
                builder.push("(");
            }
            // One IN over both id sets keeps the FTS-first plan; an OR with a correlated EXISTS walks the channel.
            builder
                .push("m.fts_rowid IN (SELECT rowid FROM messages_fts WHERE messages_fts MATCH ");
            builder.push_bind(q.to_owned());
            builder.push(
                " UNION ALL SELECT am.fts_rowid FROM attachment_text t \
                 JOIN message_attachments ma ON ma.sha256 = t.sha256 \
                 JOIN messages am ON am.id = ma.message_id \
                 WHERE am.is_encrypted = 0 AND ",
            );
            builder.push(TRANSCRIPT_TEXT_SHOWN);
            builder.push(
                " AND t.fts_rowid IN \
                 (SELECT rowid FROM attachment_text_fts WHERE attachment_text_fts MATCH ",
            );
            builder.push_bind(q.to_owned());
            builder.push(
                ") UNION ALL SELECT nm.fts_rowid FROM attachment_name_index n \
                 JOIN messages nm ON nm.id = n.message_id \
                 WHERE nm.is_encrypted = 0 AND n.fts_rowid IN \
                 (SELECT rowid FROM attachment_name_fts WHERE attachment_name_fts MATCH ",
            );
            builder.push_bind(q.to_owned());
            builder.push(
                ") UNION ALL SELECT em.fts_rowid FROM message_extra_text x \
                 JOIN messages em ON em.id = x.message_id \
                 WHERE em.is_encrypted = 0 AND x.id IN \
                 (SELECT rowid FROM message_extra_fts WHERE message_extra_fts MATCH ",
            );
            builder.push_bind(q.to_owned());
            builder.push("))");
            if let Some(unsegmented) = &query.unsegmented {
                builder.push(" OR ");
                push_unsegmented(&mut builder, unsegmented);
                builder.push(")");
            }
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
        // A per-channel seq means nothing across channels; before_id is the cursor whenever it is given.
        let seq_ceiling = if filters.before_id.is_some() {
            None
        } else {
            before_seq
        };
        builder.push_bind(seq_ceiling.unwrap_or(i64::MAX));
        filters.push_predicates(&mut builder);
        builder.push(" ORDER BY m.created_at DESC, m.seq DESC, m.id DESC LIMIT ");
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

fn probe_outcome<T>(probed: Result<T, sqlx::Error>) -> Result<(), SearchError> {
    match probed {
        Ok(_) => Ok(()),
        Err(sqlx::Error::Database(e)) if e.code().as_deref() == Some(SQLITE_ERROR) => {
            Err(SearchError::InvalidQuery)
        }
        Err(e) => Err(e.into()),
    }
}

/// ANDs each unsegmented word as a substring of the message text, then the query's other words.
fn push_unsegmented(builder: &mut QueryBuilder<sqlx::Sqlite>, query: &Unsegmented) {
    builder.push("(");
    for (i, word) in query.words.iter().enumerate() {
        if i > 0 {
            builder.push(" AND ");
        }
        if word.chars().count() >= TRIGRAM_CHARS {
            builder.push(
                "m.fts_rowid IN (SELECT rowid FROM message_trigram_fts \
                 WHERE message_trigram_fts MATCH ",
            );
            builder.push_bind(format!("\"{word}\""));
            builder.push(")");
        } else {
            builder.push("instr(m.content, ");
            builder.push_bind(word.clone());
            builder.push(") > 0");
        }
    }
    if !query.rest.is_empty() {
        builder
            .push(" AND m.fts_rowid IN (SELECT rowid FROM messages_fts WHERE messages_fts MATCH ");
        builder.push_bind(query.rest.clone());
        builder.push(")");
    }
    builder.push(")");
}

/// The trigram tokenizer cannot match a phrase shorter than three characters.
const TRIGRAM_CHARS: usize = 3;

/// SQLite's generic result code, which FTS5 raises for every query it cannot parse.
const SQLITE_ERROR: &str = "1";
