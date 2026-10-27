// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Listing a channel's threads, split out of `threads.rs` for the review
//! budget: `docs/IMPLIED-GAPS.md` named this as missing entirely - before
//! this, the only way to find a thread was from the message it hangs off,
//! since `Store::open_thread` was `threads.rs`'s only writer and nothing
//! ever enumerated the channels it created.

use super::Store;
use crate::ids::{ChannelId, MessageId, UserId};

impl Store {
    /// How many messages the caller has not yet read in each of
    /// `thread_channel_ids` - the same predicate [`Store::unread_count`]
    /// (`store/read_state.rs`) already answers for one channel, batched over
    /// a whole page of threads in one round trip rather than one call per
    /// thread. A thread absent from the answer has zero unread, the same
    /// "not present means none" convention every other batch lookup in
    /// `threads.rs` uses. Reused by
    /// [`super::super::http::message_enrich`] (the per-message reply-count
    /// affordance) and [`Store::list_threads`] (the per-thread row in the
    /// thread list).
    pub async fn thread_unread_counts(
        &self,
        thread_channel_ids: &[ChannelId],
        viewer: UserId,
    ) -> anyhow::Result<Vec<(ChannelId, i64)>> {
        if thread_channel_ids.is_empty() {
            return Ok(Vec::new());
        }
        // Capped inside the subquery like `unread_counts`, so a huge backlog is not scanned.
        let mut builder = sqlx::QueryBuilder::new(
            "SELECT ch.id AS channel_id, (SELECT COUNT(*) FROM ( \
               SELECT 1 FROM messages m \
               WHERE m.channel_id = ch.id AND m.deleted_at IS NULL \
                 AND m.seq > COALESCE((SELECT rs.last_read_seq FROM read_states rs \
                                        WHERE rs.channel_id = ch.id AND rs.user_id = ",
        );
        builder.push_bind(viewer);
        builder.push("), 0) LIMIT ");
        builder.push_bind(super::read_state::UNREAD_COUNT_CAP);
        builder.push(")) AS unread_count FROM channels ch WHERE ch.id IN (");
        let mut separated = builder.separated(", ");
        for id in thread_channel_ids {
            separated.push_bind(*id);
        }
        builder.push(")");
        let rows = builder.build().fetch_all(&self.pool).await?;

        use sqlx::Row;
        let mut counts = Vec::new();
        for row in rows {
            let unread_count: i64 = row.try_get("unread_count")?;
            if unread_count > 0 {
                counts.push((row.try_get("channel_id")?, unread_count));
            }
        }
        Ok(counts)
    }

    /// Every live thread hanging off a message in `channel_id`, newest
    /// activity first (a thread with a reply sorts on that reply; one with
    /// none yet sorts on when it was opened).
    ///
    /// Bounded by `MAX_THREADS_PER_CHANNEL` (`threads.rs`) at the write, so
    /// this answers with the whole set rather than paging the way
    /// `/reports` has to - the same trade [`Store::list_pinned_messages`]
    /// makes for the same reason.
    pub async fn list_threads(
        &self,
        channel_id: ChannelId,
        viewer: UserId,
    ) -> anyhow::Result<Vec<ThreadListItem>> {
        let mut builder = sqlx::QueryBuilder::new(
            "SELECT c.id AS thread_channel_id, c.created_at AS created_at, \
             pm.id AS parent_message_id, pm.content AS parent_content, \
             pm.author_id AS parent_author_id, u.display_name AS parent_author_display_name, \
             COUNT(m.id) AS reply_count, MAX(m.created_at) AS last_reply_at \
             FROM channels c \
             JOIN messages pm ON pm.id = c.parent_message_id \
             LEFT JOIN users u ON u.id = pm.author_id AND u.deleted_at IS NULL \
             LEFT JOIN messages m ON m.channel_id = c.id AND m.deleted_at IS NULL \
             WHERE pm.channel_id = ",
        );
        builder.push_bind(channel_id);
        builder.push(
            " AND pm.deleted_at IS NULL AND c.deleted_at IS NULL \
              GROUP BY c.id \
              ORDER BY COALESCE(MAX(m.created_at), c.created_at) DESC",
        );
        let rows = builder.build().fetch_all(&self.pool).await?;

        use sqlx::Row;
        let mut items = Vec::with_capacity(rows.len());
        let mut thread_channel_ids = Vec::with_capacity(rows.len());
        for row in rows {
            let thread_channel_id: ChannelId = row.try_get("thread_channel_id")?;
            thread_channel_ids.push(thread_channel_id);
            items.push(ThreadListItem {
                thread_channel_id,
                created_at: row.try_get("created_at")?,
                parent_message_id: row.try_get("parent_message_id")?,
                parent_content: row.try_get("parent_content")?,
                parent_author_id: row.try_get("parent_author_id")?,
                parent_author_display_name: row.try_get("parent_author_display_name")?,
                reply_count: row.try_get("reply_count")?,
                last_reply_at: row.try_get("last_reply_at")?,
                // Filled in below in one more batched query, not one lookup per row.
                unread_count: 0,
            });
        }

        let unread = self
            .thread_unread_counts(&thread_channel_ids, viewer)
            .await?;
        for item in &mut items {
            item.unread_count = unread
                .iter()
                .find(|(id, _)| *id == item.thread_channel_id)
                .map(|(_, count)| *count)
                .unwrap_or(0);
        }
        Ok(items)
    }
}

/// One row of [`Store::list_threads`]: a thread, its parent message's own
/// content and author (so a listing can show what the thread is about
/// without a second fetch), and how busy and how read it is.
pub struct ThreadListItem {
    pub thread_channel_id: ChannelId,
    /// When the thread was opened, unix milliseconds. Only ever the sort key
    /// for a thread with no replies yet - see [`Store::list_threads`]'s own
    /// `ORDER BY`.
    pub created_at: i64,
    pub parent_message_id: MessageId,
    /// The parent message's current text, joined at read time exactly like
    /// [`Store::list_pinned_messages`] joins the pinned message's own -
    /// never a snapshot, so an edit to the parent is reflected the next time
    /// this listing is fetched rather than frozen at whenever the thread
    /// opened.
    pub parent_content: String,
    /// Null once the parent's author account is anonymized, the same reason
    /// `Message::author_id` goes null.
    pub parent_author_id: Option<UserId>,
    pub parent_author_display_name: Option<String>,
    pub reply_count: i64,
    pub last_reply_at: Option<i64>,
    /// How many of this thread's live messages the caller has not yet read -
    /// [`Store::thread_unread_counts`]'s own answer for this one channel,
    /// zero for a thread the caller has fully read or never fell behind on.
    pub unread_count: i64,
}
