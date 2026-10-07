// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Polls: a message attachment with 2-4 fixed ordered options and one vote per
//! user, changeable but never doubled.
//!
//! Creating a poll is creating a message, so [`Store::send_poll_message`]
//! mirrors [`super::messages::Store::send_message`] closely: same idempotent-
//! by-id scoping, same per-channel `seq` allocation in the same transaction as
//! the insert, just with the poll and its options inserted alongside. A poll
//! never outlives or moves between messages, so it is keyed by `message_id`
//! rather than a surrogate id of its own - the same choice pinned messages
//! made for the same reason.
//!
//! Votes are read-then-write (does the poll exist, is it still open, is the
//! option real), so [`Store::vote_poll`] runs inside [`Store::begin_write`]:
//! a plain deferred transaction cannot promote itself to a writer once
//! another connection holds the write lock, and returns SQLITE_BUSY at once
//! rather than queuing (see the module docs on `begin_write`).

use sqlx::QueryBuilder;

use super::messages::row::{IdProbe, NewRow, insert_message_row, probe_id};
use super::{Sent, Store, now_ms};
use crate::ids::{ChannelId, MessageId, UserId};

/// Fewest options a poll may have. Below this it is not a choice.
pub const MIN_OPTIONS: usize = 2;
/// Most options a poll may have, matching the client's rendered layout.
pub const MAX_OPTIONS: usize = 4;
/// Longest a poll question may be, in characters.
pub const MAX_QUESTION_CHARS: usize = 300;
/// Longest one option's label may be, in characters.
pub const MAX_OPTION_CHARS: usize = 100;

/// The poll a message carries, as submitted: not yet validated.
pub struct NewPoll<'a> {
    pub question: &'a str,
    pub options: &'a [String],
    /// Unix milliseconds. `None` means the poll never closes.
    pub close_at: Option<i64>,
}

/// One option within a poll, with its current public tally.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PollOption {
    pub position: i64,
    pub label: String,
    pub votes: i64,
}

/// A poll attached to a message, as read by one particular viewer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Poll {
    pub question: String,
    /// Unix milliseconds. `None` means the poll never closes.
    pub close_at: Option<i64>,
    pub created_by: Option<UserId>,
    pub created_at: i64,
    pub options: Vec<PollOption>,
    /// The position the viewer themselves picked, or `None` if they have not
    /// voted. Per-viewer, exactly like `ReactionSummary::reacted`, and never
    /// broadcast to anyone but the voter: see [`Store::vote_poll`].
    pub voted_option: Option<i64>,
}

/// The per-option tally after a vote, in option order. This is what the hub
/// event carries: the whole public tally rather than a delta, and never who
/// cast which vote, exactly like `ReactionsChanged`.
pub type PollTally = Vec<(i64, i64)>;

/// Why creating a poll message failed.
#[derive(Debug)]
pub enum CreatePollError {
    /// A message with this id already exists for a different channel or
    /// author. Mirrors `SendError::IdConflict`: a reused id must never
    /// return a foreign message.
    IdConflict,
    InvalidQuestion,
    InvalidOptionCount,
    InvalidOption,
    Internal(anyhow::Error),
}

impl From<sqlx::Error> for CreatePollError {
    fn from(err: sqlx::Error) -> Self {
        CreatePollError::Internal(err.into())
    }
}

impl From<anyhow::Error> for CreatePollError {
    fn from(err: anyhow::Error) -> Self {
        CreatePollError::Internal(err)
    }
}

/// Why casting a vote failed.
#[derive(Debug)]
pub enum VoteError {
    /// No poll exists on this message (or the message does not exist).
    UnknownPoll,
    /// The poll's `close_at` has passed. Refused server-side, not merely
    /// hidden by the client: a client clock cannot be trusted to enforce it.
    PollClosed,
    /// `option` is not one of this poll's positions.
    InvalidOption,
    Internal(anyhow::Error),
}

impl From<sqlx::Error> for VoteError {
    fn from(err: sqlx::Error) -> Self {
        VoteError::Internal(err.into())
    }
}

impl From<anyhow::Error> for VoteError {
    fn from(err: anyhow::Error) -> Self {
        VoteError::Internal(err)
    }
}

impl Store {
    /// Sends a message carrying a poll. Idempotent by `id` within its
    /// `(channel, author)` scope, exactly like [`super::messages::Store::send_message`].
    pub async fn send_poll_message(
        &self,
        channel_id: ChannelId,
        author_id: UserId,
        id: MessageId,
        content: &str,
        poll: NewPoll<'_>,
    ) -> Result<Sent, CreatePollError> {
        let NewPoll {
            question,
            options,
            close_at,
        } = poll;
        if options.len() < MIN_OPTIONS || options.len() > MAX_OPTIONS {
            return Err(CreatePollError::InvalidOptionCount);
        }
        if question.trim().is_empty() || question.chars().count() > MAX_QUESTION_CHARS {
            return Err(CreatePollError::InvalidQuestion);
        }
        for option in options {
            if option.trim().is_empty() || option.chars().count() > MAX_OPTION_CHARS {
                return Err(CreatePollError::InvalidOption);
            }
        }

        let now = now_ms();
        // Reads the message before deciding what to write; see Store::begin_write.
        let mut tx = self.begin_write().await?;

        match probe_id(&mut tx, channel_id, author_id, id).await? {
            IdProbe::Free => {}
            IdProbe::Replay(message) => {
                tx.commit().await?;
                return Ok(Sent {
                    message,
                    fresh: false,
                });
            }
            IdProbe::Conflict => {
                tx.commit().await?;
                return Err(CreatePollError::IdConflict);
            }
        }

        // A poll message is never created as a reply.
        let message = insert_message_row(
            &mut tx,
            &NewRow {
                channel_id,
                author_id,
                id,
                content,
                reply_to_id: None,
                now,
            },
        )
        .await?;

        sqlx::query!(
            r#"INSERT INTO polls (message_id, channel_id, question, close_at, created_by, created_at)
               VALUES (?, ?, ?, ?, ?, ?)"#,
            id,
            channel_id,
            question,
            close_at,
            author_id,
            now
        )
        .execute(&mut *tx)
        .await?;

        for (position, label) in options.iter().enumerate() {
            let position = position as i64;
            sqlx::query!(
                "INSERT INTO poll_options (message_id, position, label) VALUES (?, ?, ?)",
                id,
                position,
                label
            )
            .execute(&mut *tx)
            .await?;
        }

        tx.commit().await?;
        Ok(Sent {
            message,
            fresh: true,
        })
    }

    /// Casts or changes the caller's vote. A second vote replaces the first:
    /// the primary key on `poll_votes` is `(message_id, user_id)`, so this is
    /// an upsert rather than a second row ever existing to double-count.
    ///
    /// Returns the fresh per-option tally so the caller can publish it as one
    /// hub event carrying the whole count rather than a delta.
    pub async fn vote_poll(
        &self,
        message_id: MessageId,
        user_id: UserId,
        option: i64,
    ) -> Result<PollTally, VoteError> {
        let now = now_ms();
        let mut tx = self.begin_write().await?;

        let poll = sqlx::query!(
            r#"SELECT close_at FROM polls WHERE message_id = ?"#,
            message_id
        )
        .fetch_optional(&mut *tx)
        .await?;
        let Some(poll) = poll else {
            return Err(VoteError::UnknownPoll);
        };
        // Inside the transaction and against the server's clock: a caller's
        // "it wasn't closed yet" is not something this can trust.
        if let Some(close_at) = poll.close_at
            && now >= close_at
        {
            return Err(VoteError::PollClosed);
        }

        let option_exists = sqlx::query_scalar!(
            r#"SELECT 1 AS "one!: i64" FROM poll_options WHERE message_id = ? AND position = ?"#,
            message_id,
            option
        )
        .fetch_optional(&mut *tx)
        .await?
        .is_some();
        if !option_exists {
            return Err(VoteError::InvalidOption);
        }

        sqlx::query!(
            r#"INSERT INTO poll_votes (message_id, user_id, position, voted_at)
               VALUES (?, ?, ?, ?)
               ON CONFLICT(message_id, user_id)
               DO UPDATE SET position = excluded.position, voted_at = excluded.voted_at"#,
            message_id,
            user_id,
            option,
            now
        )
        .execute(&mut *tx)
        .await?;

        let tally = fetch_tally(&mut *tx, message_id).await?;
        tx.commit().await?;
        Ok(tally)
    }

    /// A single message's poll, from one viewer's point of view. `None` if the
    /// message carries no poll.
    pub async fn poll_for_message(
        &self,
        message_id: MessageId,
        viewer: UserId,
    ) -> anyhow::Result<Option<Poll>> {
        Ok(self
            .polls_for_messages(&[message_id], viewer)
            .await?
            .into_iter()
            .next()
            .map(|(_, poll)| poll))
    }

    /// Polls for a page of messages, batch-loaded in three queries rather than
    /// one round trip per message, exactly the same reasoning
    /// `reactions_for_messages` batches on. Only messages that actually carry
    /// a poll appear in the result.
    pub async fn polls_for_messages(
        &self,
        message_ids: &[MessageId],
        viewer: UserId,
    ) -> anyhow::Result<Vec<(MessageId, Poll)>> {
        if message_ids.is_empty() {
            return Ok(Vec::new());
        }
        use sqlx::Row;

        let mut header_q = QueryBuilder::new(
            "SELECT message_id, question, close_at, created_by, created_at \
             FROM polls WHERE message_id IN (",
        );
        push_id_list(&mut header_q, message_ids);
        header_q.push(")");
        let headers = header_q.build().fetch_all(&self.pool).await?;
        if headers.is_empty() {
            return Ok(Vec::new());
        }

        let mut options_q = QueryBuilder::new(
            "SELECT o.message_id, o.position, o.label, COUNT(v.user_id) AS votes \
             FROM poll_options o \
             LEFT JOIN poll_votes v ON v.message_id = o.message_id AND v.position = o.position \
             WHERE o.message_id IN (",
        );
        push_id_list(&mut options_q, message_ids);
        options_q.push(") GROUP BY o.message_id, o.position ORDER BY o.message_id, o.position");
        let option_rows = options_q.build().fetch_all(&self.pool).await?;

        let mut mine_q =
            QueryBuilder::new("SELECT message_id, position FROM poll_votes WHERE user_id = ");
        mine_q.push_bind(viewer);
        mine_q.push(" AND message_id IN (");
        push_id_list(&mut mine_q, message_ids);
        mine_q.push(")");
        let mine_rows = mine_q.build().fetch_all(&self.pool).await?;

        let mut polls: Vec<(MessageId, Poll)> = headers
            .into_iter()
            .map(|row| {
                let message_id: MessageId = row.try_get("message_id")?;
                Ok::<_, anyhow::Error>((
                    message_id,
                    Poll {
                        question: row.try_get("question")?,
                        close_at: row.try_get("close_at")?,
                        created_by: row.try_get("created_by")?,
                        created_at: row.try_get("created_at")?,
                        options: Vec::new(),
                        voted_option: None,
                    },
                ))
            })
            .collect::<Result<_, _>>()?;

        for row in option_rows {
            let message_id: MessageId = row.try_get("message_id")?;
            if let Some((_, poll)) = polls.iter_mut().find(|(id, _)| *id == message_id) {
                poll.options.push(PollOption {
                    position: row.try_get("position")?,
                    label: row.try_get("label")?,
                    votes: row.try_get("votes")?,
                });
            }
        }

        for row in mine_rows {
            let message_id: MessageId = row.try_get("message_id")?;
            if let Some((_, poll)) = polls.iter_mut().find(|(id, _)| *id == message_id) {
                poll.voted_option = Some(row.try_get("position")?);
            }
        }

        Ok(polls)
    }
}

/// Appends a comma-separated bind list, since SQLite has no array binding and
/// the id list here is variable length.
fn push_id_list(builder: &mut QueryBuilder<sqlx::Sqlite>, ids: &[MessageId]) {
    let mut separated = builder.separated(", ");
    for id in ids {
        separated.push_bind(*id);
    }
}

/// The per-option tally for one poll, in option order. Shared by `vote_poll`
/// (to build the hub event) so a vote and its published tally always agree.
async fn fetch_tally(
    executor: impl sqlx::SqliteExecutor<'_>,
    message_id: MessageId,
) -> anyhow::Result<PollTally> {
    let rows = sqlx::query!(
        r#"SELECT o.position AS "position!: i64", COUNT(v.user_id) AS "votes!: i64"
           FROM poll_options o
           LEFT JOIN poll_votes v ON v.message_id = o.message_id AND v.position = o.position
           WHERE o.message_id = ?
           GROUP BY o.position
           ORDER BY o.position"#,
        message_id
    )
    .fetch_all(executor)
    .await?;
    Ok(rows.into_iter().map(|r| (r.position, r.votes)).collect())
}
