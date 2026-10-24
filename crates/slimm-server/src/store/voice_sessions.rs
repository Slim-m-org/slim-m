// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! One row per member per call (decision 0091), for the `log.read` capability.
//! Opened by the LiveKit join webhook and closed by its leave, so a missed
//! leave is closed by a finished room, a stale heartbeat or a restart instead.

use super::{Store, now_ms};
use crate::ids::{ChannelId, UserId};

/// How long a closed session is kept.
pub const VOICE_SESSION_RETENTION_DAYS: i64 = 90;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VoiceSession {
    pub id: i64,
    pub user_id: UserId,
    pub channel_id: ChannelId,
    pub sid: String,
    pub joined_at: i64,
    pub left_at: Option<i64>,
    pub alone_ms: i64,
    /// Where this close falls among all closes; `None` while the session is open.
    pub closed_seq: Option<i64>,
}

/// Which open sessions a close applies to.
#[derive(Debug, Clone, Copy)]
pub enum SessionScope<'a> {
    /// The member's session for this LiveKit participant sid.
    Sid(UserId, &'a str),
    /// The member's sessions in one channel.
    Member(UserId, ChannelId),
    /// Everyone in one channel, because its room finished.
    Channel(ChannelId),
    /// Every open session, because the process restarted.
    Everyone,
}

impl Store {
    /// Opens a session for `sid`. A member who still has a session open under
    /// another sid missed a leave, so that one is closed at `at` first.
    /// Returns `false` without a new row when this sid is already open.
    pub async fn open_voice_session(
        &self,
        channel: ChannelId,
        user: UserId,
        sid: &str,
        at: i64,
    ) -> anyhow::Result<bool> {
        Ok(self
            .open_voice_session_closing(channel, user, sid, at)
            .await?
            .0)
    }

    /// [`Self::open_voice_session`], also returning the earlier sessions it closed.
    pub async fn open_voice_session_closing(
        &self,
        channel: ChannelId,
        user: UserId,
        sid: &str,
        at: i64,
    ) -> anyhow::Result<(bool, Vec<VoiceSession>)> {
        let stale = sqlx::query_scalar!(
            r#"SELECT id AS "id!: i64" FROM voice_sessions
               WHERE user_id = ? AND left_at IS NULL AND sid <> ?"#,
            user,
            sid
        )
        .fetch_all(&self.pool)
        .await?;
        let closed = self.close_voice_session_ids(&stale, at).await?;
        let inserted = sqlx::query!(
            "INSERT INTO voice_sessions (user_id, channel_id, sid, joined_at)
             SELECT ?, ?, ?, ?
             WHERE NOT EXISTS (
                 SELECT 1 FROM voice_sessions WHERE user_id = ? AND sid = ? AND left_at IS NULL
             )",
            user,
            channel,
            sid,
            at,
            user,
            sid
        )
        .execute(&self.pool)
        .await?
        .rows_affected();
        Ok((inserted == 1, closed))
    }

    /// Closes the open sessions in `scope` at `at`, returning each as closed.
    pub async fn close_voice_sessions(
        &self,
        scope: SessionScope<'_>,
        at: i64,
    ) -> anyhow::Result<Vec<VoiceSession>> {
        let ids = match scope {
            SessionScope::Sid(user, sid) => {
                sqlx::query_scalar!(
                    r#"SELECT id AS "id!: i64" FROM voice_sessions
                       WHERE user_id = ? AND sid = ? AND left_at IS NULL"#,
                    user,
                    sid
                )
                .fetch_all(&self.pool)
                .await?
            }
            SessionScope::Member(user, channel) => {
                sqlx::query_scalar!(
                    r#"SELECT id AS "id!: i64" FROM voice_sessions
                       WHERE user_id = ? AND channel_id = ? AND left_at IS NULL"#,
                    user,
                    channel
                )
                .fetch_all(&self.pool)
                .await?
            }
            SessionScope::Channel(channel) => {
                sqlx::query_scalar!(
                    r#"SELECT id AS "id!: i64" FROM voice_sessions
                       WHERE channel_id = ? AND left_at IS NULL"#,
                    channel
                )
                .fetch_all(&self.pool)
                .await?
            }
            SessionScope::Everyone => {
                sqlx::query_scalar!(
                    r#"SELECT id AS "id!: i64" FROM voice_sessions WHERE left_at IS NULL"#
                )
                .fetch_all(&self.pool)
                .await?
            }
        };
        self.close_voice_session_ids(&ids, at).await
    }

    async fn close_voice_session_ids(
        &self,
        ids: &[i64],
        at: i64,
    ) -> anyhow::Result<Vec<VoiceSession>> {
        let mut closed = Vec::new();
        for id in ids {
            if let Some(session) = self.close_voice_session(*id, at).await? {
                closed.push(session);
            }
        }
        Ok(closed)
    }

    async fn close_voice_session(&self, id: i64, at: i64) -> anyhow::Result<Option<VoiceSession>> {
        let mut tx = self.begin_write().await?;
        let Some(row) = sqlx::query!(
            r#"SELECT user_id AS "user_id!: UserId", channel_id AS "channel_id!: ChannelId",
                      sid AS "sid!", joined_at AS "joined_at!: i64"
               FROM voice_sessions WHERE id = ? AND left_at IS NULL"#,
            id
        )
        .fetch_optional(&mut *tx)
        .await?
        else {
            return Ok(None);
        };
        let left = at.max(row.joined_at);
        let others = sqlx::query!(
            r#"SELECT joined_at AS "joined_at!: i64", left_at
               FROM voice_sessions
               WHERE channel_id = ? AND id <> ? AND joined_at < ?
                 AND (left_at IS NULL OR left_at > ?)"#,
            row.channel_id,
            id,
            left,
            row.joined_at
        )
        .fetch_all(&mut *tx)
        .await?;
        let spans: Vec<(i64, i64)> = others
            .iter()
            .map(|o| (o.joined_at, o.left_at.unwrap_or(left)))
            .collect();
        let alone_ms = alone_for(row.joined_at, left, spans);
        let closed_seq = sqlx::query_scalar!(
            r#"UPDATE voice_session_close_seq SET last = last + 1 WHERE id = 1
               RETURNING last AS "last!: i64""#
        )
        .fetch_one(&mut *tx)
        .await?;
        sqlx::query!(
            "UPDATE voice_sessions SET left_at = ?, alone_ms = ?, closed_seq = ? WHERE id = ?",
            left,
            alone_ms,
            closed_seq,
            id
        )
        .execute(&mut *tx)
        .await?;
        tx.commit().await?;
        Ok(Some(VoiceSession {
            id,
            user_id: row.user_id,
            channel_id: row.channel_id,
            sid: row.sid,
            joined_at: row.joined_at,
            left_at: Some(left),
            alone_ms,
            closed_seq: Some(closed_seq),
        }))
    }

    /// Closed sessions with a `closed_seq` above `cursor`, in close order. The
    /// sequence is handed out at the moment of closing, so a later close always
    /// lands above a cursor that has passed the earlier ones and an open
    /// session never holds the others back.
    pub async fn closed_voice_sessions_after(
        &self,
        cursor: i64,
        limit: i64,
    ) -> anyhow::Result<Vec<VoiceSession>> {
        let rows = sqlx::query!(
            r#"SELECT id AS "id!: i64", user_id AS "user_id!: UserId",
                      channel_id AS "channel_id!: ChannelId", sid AS "sid!",
                      joined_at AS "joined_at!: i64", left_at AS "left_at!: i64",
                      alone_ms AS "alone_ms!: i64", closed_seq AS "closed_seq!: i64"
               FROM voice_sessions
               WHERE closed_seq > ?
               ORDER BY closed_seq LIMIT ?"#,
            cursor,
            limit
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .into_iter()
            .map(|r| VoiceSession {
                id: r.id,
                user_id: r.user_id,
                channel_id: r.channel_id,
                sid: r.sid,
                joined_at: r.joined_at,
                left_at: Some(r.left_at),
                alone_ms: r.alone_ms,
                closed_seq: Some(r.closed_seq),
            })
            .collect())
    }

    /// Deletes closed sessions past retention; the sweep calls this.
    pub async fn sweep_voice_sessions(&self) -> anyhow::Result<u64> {
        let before = now_ms() - VOICE_SESSION_RETENTION_DAYS * 24 * 60 * 60 * 1000;
        Ok(sqlx::query!(
            "DELETE FROM voice_sessions WHERE left_at IS NOT NULL AND left_at < ?",
            before
        )
        .execute(&self.pool)
        .await?
        .rows_affected())
    }
}

/// The part of `joined..left` that no span in `others` covers.
fn alone_for(joined: i64, left: i64, mut others: Vec<(i64, i64)>) -> i64 {
    others.sort_unstable();
    let mut covered = 0;
    let mut reach = joined;
    for (start, end) in others {
        let (start, end) = (start.max(reach), end.min(left));
        if end > start {
            covered += end - start;
            reach = end;
        }
    }
    (left - joined - covered).max(0)
}

#[cfg(test)]
mod tests {
    use super::alone_for;

    #[test]
    fn the_whole_span_is_alone_with_no_company() {
        assert_eq!(alone_for(100, 400, vec![]), 300);
    }

    #[test]
    fn overlapping_company_is_counted_once() {
        let others = vec![(150, 250), (200, 300), (50, 120)];
        assert_eq!(alone_for(100, 400, others), 130);
    }

    #[test]
    fn company_for_the_whole_span_leaves_none() {
        assert_eq!(alone_for(100, 400, vec![(0, 500)]), 0);
    }
}
