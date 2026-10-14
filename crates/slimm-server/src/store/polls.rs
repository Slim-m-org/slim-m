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
use super::poll_runoff::{Runoff, instant_runoff};
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
    /// Voters rank the options and the result is an instant runoff.
    pub ranked: bool,
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
    /// On a ranked poll this is the viewer's first choice.
    pub voted_option: Option<i64>,
    pub ranked: bool,
    /// The viewer's own full ranking on a ranked poll, best first. Per-viewer
    /// for the same reason as `voted_option`.
    pub voted_ranking: Option<Vec<i64>>,
    /// The instant-runoff count, on a ranked poll only.
    pub runoff: Option<Runoff>,
}

/// The per-option tally after a vote, in option order. This is what the hub
/// event carries: the whole public tally rather than a delta, and never who
/// cast which vote, exactly like `ReactionsChanged`.
pub type PollTally = Vec<(i64, i64)>;

/// What a vote changed, for the hub event: the first-choice tally, plus the
/// runoff on a ranked poll.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VoteOutcome {
    pub tally: PollTally,
    pub runoff: Option<Runoff>,
}

/// A vote as cast: one option on an ordinary poll, or a ranking (best first,
/// not necessarily every option) on a ranked one.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Ballot {
    Single(i64),
    Ranked(Vec<i64>),
}

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
    /// `option` is not one of this poll's positions, or a ranking is empty,
    /// repeats an option or names one this poll does not have.
    InvalidOption,
    /// A single option sent to a ranked poll, or a ranking to an ordinary one.
    WrongBallot {
        ranked: bool,
    },
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
            ranked,
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
            r#"INSERT INTO polls (message_id, channel_id, question, close_at, created_by, created_at, ranked)
               VALUES (?, ?, ?, ?, ?, ?, ?)"#,
            id,
            channel_id,
            question,
            close_at,
            author_id,
            now,
            ranked
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
    /// an upsert rather than a second row ever existing to double-count. A
    /// ranked ballot stores its first choice there too, and its whole order
    /// in `poll_rankings`, replaced as one.
    ///
    /// Returns the fresh tally (and runoff) so the caller can publish it as
    /// one hub event carrying the whole count rather than a delta.
    pub async fn vote_poll(
        &self,
        message_id: MessageId,
        user_id: UserId,
        ballot: Ballot,
    ) -> Result<VoteOutcome, VoteError> {
        let now = now_ms();
        let mut tx = self.begin_write().await?;

        let poll = sqlx::query!(
            r#"SELECT close_at, ranked AS "ranked: bool" FROM polls WHERE message_id = ?"#,
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

        let ranking = match (ballot, poll.ranked) {
            (Ballot::Single(option), false) => vec![option],
            (Ballot::Ranked(ranking), true) => ranking,
            (_, ranked) => return Err(VoteError::WrongBallot { ranked }),
        };
        let positions = option_positions(&mut *tx, message_id).await?;
        let mut seen = Vec::with_capacity(ranking.len());
        for position in &ranking {
            if !positions.contains(position) || seen.contains(position) {
                return Err(VoteError::InvalidOption);
            }
            seen.push(*position);
        }
        let Some(&first) = ranking.first() else {
            return Err(VoteError::InvalidOption);
        };

        sqlx::query!(
            r#"INSERT INTO poll_votes (message_id, user_id, position, voted_at)
               VALUES (?, ?, ?, ?)
               ON CONFLICT(message_id, user_id)
               DO UPDATE SET position = excluded.position, voted_at = excluded.voted_at"#,
            message_id,
            user_id,
            first,
            now
        )
        .execute(&mut *tx)
        .await?;

        if poll.ranked {
            sqlx::query!(
                "DELETE FROM poll_rankings WHERE message_id = ? AND user_id = ?",
                message_id,
                user_id
            )
            .execute(&mut *tx)
            .await?;
            for (rank, position) in ranking.iter().enumerate() {
                let rank = rank as i64;
                sqlx::query!(
                    "INSERT INTO poll_rankings (message_id, user_id, rank, position) VALUES (?, ?, ?, ?)",
                    message_id,
                    user_id,
                    rank,
                    position
                )
                .execute(&mut *tx)
                .await?;
            }
        }

        let tally = fetch_tally(&mut *tx, message_id).await?;
        let runoff = if poll.ranked {
            let ballots = fetch_ballots(&mut *tx, &[message_id])
                .await?
                .into_iter()
                .map(|(_, _, ballot)| ballot)
                .collect::<Vec<_>>();
            Some(instant_runoff(&positions, &ballots))
        } else {
            None
        };
        tx.commit().await?;
        Ok(VoteOutcome { tally, runoff })
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
            "SELECT message_id, question, close_at, created_by, created_at, ranked \
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
                        ranked: row.try_get("ranked")?,
                        voted_ranking: None,
                        runoff: None,
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

        let ranked_ids: Vec<MessageId> = polls
            .iter()
            .filter(|(_, poll)| poll.ranked)
            .map(|(id, _)| *id)
            .collect();
        if !ranked_ids.is_empty() {
            let ballots = fetch_ballots(&self.pool, &ranked_ids).await?;
            for (message_id, poll) in polls.iter_mut().filter(|(_, poll)| poll.ranked) {
                let mine: Vec<&Vec<i64>> = ballots
                    .iter()
                    .filter(|(id, voter, _)| id == message_id && *voter == viewer)
                    .map(|(_, _, ballot)| ballot)
                    .collect();
                poll.voted_ranking = mine.first().map(|ballot| (*ballot).clone());
                let these: Vec<Vec<i64>> = ballots
                    .iter()
                    .filter(|(id, _, _)| id == message_id)
                    .map(|(_, _, ballot)| ballot.clone())
                    .collect();
                let positions: Vec<i64> = poll.options.iter().map(|o| o.position).collect();
                poll.runoff = Some(instant_runoff(&positions, &these));
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

async fn option_positions(
    executor: impl sqlx::SqliteExecutor<'_>,
    message_id: MessageId,
) -> anyhow::Result<Vec<i64>> {
    Ok(sqlx::query_scalar!(
        r#"SELECT position AS "position!: i64" FROM poll_options WHERE message_id = ? ORDER BY position"#,
        message_id
    )
    .fetch_all(executor)
    .await?)
}

/// Every ranked ballot on these polls as `(message, voter, ranking)`, each
/// ranking best first.
async fn fetch_ballots(
    executor: impl sqlx::SqliteExecutor<'_>,
    message_ids: &[MessageId],
) -> anyhow::Result<Vec<(MessageId, UserId, Vec<i64>)>> {
    use sqlx::Row;
    let mut q = QueryBuilder::new(
        "SELECT message_id, user_id, position FROM poll_rankings WHERE message_id IN (",
    );
    push_id_list(&mut q, message_ids);
    q.push(") ORDER BY message_id, user_id, rank");
    let mut ballots: Vec<(MessageId, UserId, Vec<i64>)> = Vec::new();
    for row in q.build().fetch_all(executor).await? {
        let message_id: MessageId = row.try_get("message_id")?;
        let user_id: UserId = row.try_get("user_id")?;
        let position: i64 = row.try_get("position")?;
        match ballots.last_mut() {
            Some((m, u, ranking)) if *m == message_id && *u == user_id => ranking.push(position),
            _ => ballots.push((message_id, user_id, vec![position])),
        }
    }
    Ok(ballots)
}
