// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Selecting one author's recent live messages in a channel, for
//! `http/messages_bulk_window.rs`'s window-based sibling of
//! [`Store::bulk_delete_messages`].
//!
//! Kept apart from `messages_bulk.rs` for the same reason that file is
//! already split from `messages.rs`: a second, differently-shaped selection
//! reads as an aside next to the id-list one rather than a natural growth of
//! it. The write path itself is not duplicated - this module only turns a
//! `(channel, author, since)` predicate into an id list, and hands that
//! straight to [`Store::bulk_delete_messages`].

use super::Store;
use crate::ids::{ChannelId, MessageId, UserId};

impl Store {
    /// Ids of [author_id]'s live messages in [channel_id] created at or after
    /// [since_ms], at most [limit] of them.
    ///
    /// [limit] is deliberately the caller's cap plus one: asking for one more
    /// row than the caller intends to allow is how it tells "matched exactly
    /// the cap" apart from "matched over it" without a separate `COUNT(*)`
    /// query, so a refusal can be a refusal rather than a silent truncation
    /// to the first [limit] rows.
    ///
    /// Seeks `messages_author_channel_window`
    /// (`channel_id, author_id, created_at WHERE deleted_at IS NULL`, added
    /// by migration 0054) rather than either index that predates it:
    /// `messages_channel_live` has no author column, and `messages_author`
    /// has no channel or time column, so together they still leave this
    /// predicate unindexed. Pinned with `INDEXED BY` because the unfiltered
    /// `messages_author_channel_sent` (0099) matches the same keys and the planner may pick it.
    /// Proved by `tests/messages_bulk_window_index_plan.rs`.
    pub async fn message_ids_by_author_since(
        &self,
        channel_id: ChannelId,
        author_id: UserId,
        since_ms: i64,
        limit: i64,
    ) -> anyhow::Result<Vec<MessageId>> {
        let ids = sqlx::query_scalar!(
            r#"SELECT id AS "id!: MessageId" FROM messages
                 INDEXED BY messages_author_channel_window
               WHERE channel_id = ? AND author_id = ? AND created_at >= ?
                 AND deleted_at IS NULL
               LIMIT ?"#,
            channel_id,
            author_id,
            since_ms,
            limit,
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(ids)
    }
}
