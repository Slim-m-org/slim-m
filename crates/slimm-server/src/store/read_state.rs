// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Read state and the catch-up read path.
//!
//! Read state is a per-(user, channel) monotonic `last_read_seq`. Unread is not
//! stored; it is derived on demand as a range count of live messages past that
//! seq, stopping at [`UNREAD_COUNT_CAP`], which the `(channel_id, seq)` index answers cheaply. Catch-up returns
//! the messages after a client's per-scope cursor in ascending order, which the
//! bundled sync endpoint calls once per requested scope.

use std::collections::HashMap;

use sqlx::QueryBuilder;

use super::{Message, Store, now_ms};
use crate::ids::{ChannelId, MessageId, Seq, UserId};

/// Most unread messages one count reports; the client shows anything past 99 as "99+".
pub const UNREAD_COUNT_CAP: i64 = 1000;

impl Store {
    /// Advances a user's last-read marker in a channel. Monotonic: a lower seq
    /// never moves it backwards, so out-of-order marks are safe.
    ///
    /// Also clears any manual unread mark ([`Store::mark_unread`]). Reading a
    /// channel is the natural undo for "remind me about this", and doing it
    /// here rather than in a second call means the two can never disagree: a
    /// client that catches up has, by definition, stopped needing the note.
    ///
    /// Clamped to what the channel has actually reached, because the monotonic
    /// `MAX` below makes an over-large value permanent: one mark of `i64::MAX`
    /// pinned the marker there for good and left the unread count reading zero
    /// for every future message, with nothing in the API able to lower it again.
    /// Only `VIEW_CHANNEL` is needed to reach this, and the counter read is a
    /// single indexed lookup rather than a scan of the messages.
    ///
    /// Returns the stored marker when the row changed (the marker advanced or
    /// a manual unread was cleared) and `None` for a mark that moved nothing,
    /// so a caller can skip announcing a no-op.
    pub async fn mark_read(
        &self,
        user_id: UserId,
        channel_id: ChannelId,
        seq: i64,
    ) -> anyhow::Result<Option<i64>> {
        let seq = seq.min(self.latest_message_seq(channel_id).await?);
        let now = now_ms();
        let stored = sqlx::query_scalar!(
            r#"INSERT INTO read_states (user_id, channel_id, last_read_seq, updated_at)
             VALUES (?, ?, ?, ?)
             ON CONFLICT(user_id, channel_id) DO UPDATE SET
                 last_read_seq = MAX(last_read_seq, excluded.last_read_seq),
                 manually_unread = 0,
                 updated_at = excluded.updated_at
             WHERE excluded.last_read_seq > last_read_seq OR manually_unread != 0
             RETURNING last_read_seq AS "last_read_seq!: i64""#,
            user_id,
            channel_id,
            seq,
            now
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(stored)
    }

    /// Marks a channel unread without moving the read marker backwards.
    ///
    /// The marker is monotonic by design (see [`Store::mark_read`]), so this
    /// records the intent beside it instead. `last_read_seq` keeps meaning
    /// "the furthest this person has read"; this means "show it as unread
    /// anyway". They answer different questions and so cannot contradict.
    ///
    /// Inserts a row when one does not exist yet, because a channel nobody has
    /// ever opened can still be marked - it already reads as unread, and the
    /// mark is what survives them opening and leaving it.
    ///
    /// Returns the stored marker when the mark is new and `None` when the
    /// channel was already marked, so a caller can skip announcing a no-op.
    pub async fn mark_unread(
        &self,
        user_id: UserId,
        channel_id: ChannelId,
    ) -> anyhow::Result<Option<i64>> {
        let now = now_ms();
        let stored = sqlx::query_scalar!(
            r#"INSERT INTO read_states (user_id, channel_id, last_read_seq, manually_unread, updated_at)
             VALUES (?, ?, 0, 1, ?)
             ON CONFLICT(user_id, channel_id) DO UPDATE SET
                 manually_unread = 1,
                 updated_at = excluded.updated_at
             WHERE manually_unread = 0
             RETURNING last_read_seq AS "last_read_seq!: i64""#,
            user_id,
            channel_id,
            now
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(stored)
    }

    /// Whether this user asked to see this channel as unread.
    pub async fn manually_unread(
        &self,
        user_id: UserId,
        channel_id: ChannelId,
    ) -> anyhow::Result<bool> {
        let flag = sqlx::query_scalar!(
            r#"SELECT manually_unread AS "flag!: i64"
               FROM read_states WHERE user_id = ? AND channel_id = ?"#,
            user_id,
            channel_id
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(flag.unwrap_or(0) != 0)
    }

    /// A user's last-read seq in a channel, or 0 if they have never read it.
    pub async fn last_read_seq(
        &self,
        user_id: UserId,
        channel_id: ChannelId,
    ) -> anyhow::Result<i64> {
        let seq = sqlx::query_scalar!(
            r#"SELECT last_read_seq AS "seq!: i64"
               FROM read_states WHERE user_id = ? AND channel_id = ?"#,
            user_id,
            channel_id
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(seq.unwrap_or(0))
    }

    /// Each listed user's last-read seq in one channel; a user with no row is
    /// absent, which callers read as 0, matching [`Store::last_read_seq`].
    pub async fn last_read_seqs(
        &self,
        channel_id: ChannelId,
        user_ids: &[UserId],
    ) -> anyhow::Result<HashMap<UserId, i64>> {
        use sqlx::Row;

        let mut seqs = HashMap::new();
        for chunk in user_ids.chunks(super::MAX_IDS_PER_QUERY - 1) {
            // Built, not a fixed query!: a variable-length id list, the shape unread_counts uses.
            let mut builder = QueryBuilder::new(
                "SELECT user_id, last_read_seq FROM read_states WHERE channel_id = ",
            );
            builder.push_bind(channel_id);
            builder.push(" AND user_id IN (");
            let mut separated = builder.separated(", ");
            for id in chunk {
                separated.push_bind(*id);
            }
            builder.push(")");
            for row in builder.build().fetch_all(&self.pool).await? {
                seqs.insert(row.try_get("user_id")?, row.try_get("last_read_seq")?);
            }
        }
        Ok(seqs)
    }

    /// The count of live messages a user has not read in a channel, capped at [`UNREAD_COUNT_CAP`].
    pub async fn unread_count(
        &self,
        user_id: UserId,
        channel_id: ChannelId,
    ) -> anyhow::Result<i64> {
        let count = sqlx::query_scalar!(
            r#"SELECT COUNT(*) AS "count!: i64" FROM (
                 SELECT 1 FROM messages
                 WHERE channel_id = ? AND deleted_at IS NULL
                   AND seq > COALESCE(
                       (SELECT last_read_seq FROM read_states
                        WHERE user_id = ? AND channel_id = ?),
                       0)
                 LIMIT ?)"#,
            channel_id,
            user_id,
            channel_id,
            UNREAD_COUNT_CAP
        )
        .fetch_one(&self.pool)
        .await?;
        Ok(count)
    }

    /// [`unread_count`] for many channels in one query, so a caller listing N
    /// channels does not pay N round trips; see [`Store::list_dm_conversations`].
    ///
    /// A channel with nothing unread is absent from the map, not present with
    /// a zero, and the caller reads a missing entry as zero. A channel the
    /// user has never opened counts from zero, matching [`unread_count`], and
    /// every count stops at [`UNREAD_COUNT_CAP`].
    pub async fn unread_counts(
        &self,
        user_id: UserId,
        channel_ids: &[ChannelId],
    ) -> anyhow::Result<HashMap<ChannelId, i64>> {
        use sqlx::Row;

        // Reserve two binds (user_id, cap) under the chunk limit; empty makes no chunks and returns empty.
        let mut counts = HashMap::new();
        for chunk in channel_ids.chunks(super::MAX_IDS_PER_QUERY - 2) {
            // Built, not a fixed query!: a variable-length id list with no SQLite array binding, user_profiles' shape.
            let mut builder = QueryBuilder::new(
                "SELECT ch.id AS channel_id, (SELECT COUNT(*) FROM ( \
                   SELECT 1 FROM messages m \
                   WHERE m.channel_id = ch.id AND m.deleted_at IS NULL \
                     AND m.seq > COALESCE((SELECT r.last_read_seq FROM read_states r \
                                           WHERE r.channel_id = ch.id AND r.user_id = ",
            );
            builder.push_bind(user_id);
            builder.push("), 0) LIMIT ");
            builder.push_bind(UNREAD_COUNT_CAP);
            builder.push(")) AS count FROM channels ch WHERE ch.id IN (");
            let mut separated = builder.separated(", ");
            for id in chunk {
                separated.push_bind(*id);
            }
            builder.push(")");

            for row in builder.build().fetch_all(&self.pool).await? {
                let count: i64 = row.try_get("count")?;
                if count > 0 {
                    counts.insert(row.try_get("channel_id")?, count);
                }
            }
        }
        Ok(counts)
    }

    /// The highest message seq allocated in a channel, or 0 if none. Used to size
    /// the gap a catch-up must cover without scanning the message rows.
    pub async fn latest_message_seq(&self, channel_id: ChannelId) -> anyhow::Result<i64> {
        let seq = sqlx::query_scalar!(
            r#"SELECT (next_seq - 1) AS "seq!: i64"
               FROM channel_seq_counters
               WHERE channel_id = ? AND stream = 'message'"#,
            channel_id
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(seq.unwrap_or(0))
    }

    /// Live messages after `after_seq`, oldest first, for catch-up. The caller
    /// passes `limit + 1` to detect whether more remain.
    pub async fn messages_since(
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
}
