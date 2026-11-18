// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! When each member last posted, for the role editor's add list.
//!
//! Computed on read from `messages` like the analytics totals, and only over
//! channels the caller names and the threads under them, so it never says
//! more than those channels already show.

use std::collections::HashMap;

use sqlx::{QueryBuilder, Row};

use super::Store;
use crate::ids::{ChannelId, UserId};

impl Store {
    /// Each author's newest live message across `channel_ids` and the live
    /// threads hanging from their messages, in Unix milliseconds.
    pub async fn last_posted_in(
        &self,
        channel_ids: &[ChannelId],
    ) -> anyhow::Result<HashMap<UserId, i64>> {
        if channel_ids.is_empty() {
            return Ok(HashMap::new());
        }
        let mut builder = QueryBuilder::new("WITH visible(id) AS (VALUES ");
        for (index, id) in channel_ids.iter().enumerate() {
            builder.push(if index == 0 { "(" } else { ", (" });
            builder.push_bind(*id);
            builder.push(")");
        }
        // A thread inherits its parent channel's view (decision 0005), so its replies count with it.
        builder.push(
            ") SELECT author_id, MAX(created_at) AS last_posted_at FROM messages \
             WHERE deleted_at IS NULL AND author_id IS NOT NULL AND channel_id IN ( \
               SELECT id FROM visible \
               UNION SELECT t.id FROM channels t JOIN messages p ON p.id = t.parent_message_id \
               WHERE t.deleted_at IS NULL AND p.deleted_at IS NULL \
                 AND p.channel_id IN (SELECT id FROM visible)) \
             GROUP BY author_id",
        );

        let mut latest = HashMap::new();
        for row in builder.build().fetch_all(&self.pool).await? {
            latest.insert(row.try_get("author_id")?, row.try_get("last_posted_at")?);
        }
        Ok(latest)
    }
}
