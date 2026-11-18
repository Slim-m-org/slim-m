// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! When each member last posted, for the role editor's add list.
//!
//! Computed on read from `messages` like the analytics totals, and only over
//! channels the caller names, so it never says more than those channels already show.

use std::collections::HashMap;

use sqlx::{QueryBuilder, Row};

use super::Store;
use crate::ids::{ChannelId, UserId};

impl Store {
    /// Each author's newest live message across `channel_ids`, in Unix milliseconds.
    pub async fn last_posted_in(
        &self,
        channel_ids: &[ChannelId],
    ) -> anyhow::Result<HashMap<UserId, i64>> {
        if channel_ids.is_empty() {
            return Ok(HashMap::new());
        }
        let mut builder = QueryBuilder::new(
            "SELECT author_id, MAX(created_at) AS last_posted_at FROM messages \
             WHERE deleted_at IS NULL AND author_id IS NOT NULL AND channel_id IN (",
        );
        let mut separated = builder.separated(", ");
        for id in channel_ids {
            separated.push_bind(*id);
        }
        builder.push(") GROUP BY author_id");

        let mut latest = HashMap::new();
        for row in builder.build().fetch_all(&self.pool).await? {
            latest.insert(row.try_get("author_id")?, row.try_get("last_posted_at")?);
        }
        Ok(latest)
    }
}
