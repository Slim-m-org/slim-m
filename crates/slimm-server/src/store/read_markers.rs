// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A user's read markers across many channels in one query.

use sqlx::QueryBuilder;

use super::Store;
use super::read_state::UNREAD_COUNT_CAP;
use crate::ids::{ChannelId, UserId};

/// One channel's read state for one user, the same three facts the per-channel route answers.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChannelReadState {
    pub channel_id: ChannelId,
    pub last_read_seq: i64,
    pub unread: i64,
    pub manually_unread: bool,
}

impl Store {
    /// Every listed channel's read state for `user_id`, ordered by channel id.
    ///
    /// A channel the user never opened is still answered, with a zero marker
    /// and every live message unread, exactly as [`Store::last_read_seq`] and
    /// [`Store::unread_count`] answer it one channel at a time, `unread` stopping
    /// at [`UNREAD_COUNT_CAP`]. Authorizing the ids is the caller's job; this
    /// only reads this one user's rows.
    pub async fn read_states_for(
        &self,
        user_id: UserId,
        channel_ids: &[ChannelId],
    ) -> anyhow::Result<Vec<ChannelReadState>> {
        use sqlx::Row;

        let mut states = Vec::with_capacity(channel_ids.len());
        // Two binds are the cap and the user, so the chunk leaves room for them under the limit.
        for chunk in channel_ids.chunks(super::MAX_IDS_PER_QUERY - 2) {
            // Built, not a fixed query!: a variable-length id list with no SQLite array binding.
            let mut builder = QueryBuilder::new(
                "SELECT c.id AS channel_id, \
                        COALESCE(r.last_read_seq, 0) AS last_read_seq, \
                        COALESCE(r.manually_unread, 0) AS manually_unread, \
                        (SELECT COUNT(*) FROM ( \
                           SELECT 1 FROM messages m \
                           WHERE m.channel_id = c.id AND m.deleted_at IS NULL \
                             AND m.seq > COALESCE(r.last_read_seq, 0) \
                           LIMIT ",
            );
            builder.push_bind(UNREAD_COUNT_CAP);
            builder.push(
                ")) AS unread \
                 FROM channels c \
                 LEFT JOIN read_states r ON r.channel_id = c.id AND r.user_id = ",
            );
            builder.push_bind(user_id);
            builder.push(" WHERE c.id IN (");
            let mut separated = builder.separated(", ");
            for id in chunk {
                separated.push_bind(*id);
            }
            builder.push(") ORDER BY c.id");
            for row in builder.build().fetch_all(&self.pool).await? {
                states.push(ChannelReadState {
                    channel_id: row.try_get("channel_id")?,
                    last_read_seq: row.try_get("last_read_seq")?,
                    unread: row.try_get("unread")?,
                    manually_unread: row.try_get::<i64, _>("manually_unread")? != 0,
                });
            }
        }
        Ok(states)
    }
}
