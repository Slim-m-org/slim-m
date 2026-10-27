// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Reading polls back for a viewer: one message or a whole page in a few queries.

use sqlx::QueryBuilder;

use super::{Poll, PollOption, Store};
use crate::ids::{MessageId, UserId};
use crate::store::poll_runoff::instant_runoff;

impl Store {
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

/// Every ranked ballot on these polls as `(message, voter, ranking)`, each
/// ranking best first.
pub(super) async fn fetch_ballots(
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
