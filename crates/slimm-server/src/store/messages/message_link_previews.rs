// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Per-message link-preview suppression: a side table, never a column on
//! [`super::super::Message`]. A row means the message's cards were removed.

use std::collections::HashSet;

use crate::ids::MessageId;

use super::super::{Store, now_ms};

impl Store {
    /// Records that `message_id`'s link previews were removed. Idempotent: a
    /// second removal keeps the first row, and returns `false` so the caller
    /// can skip a redundant broadcast.
    pub async fn suppress_link_previews(&self, message_id: MessageId) -> anyhow::Result<bool> {
        let now = now_ms();
        let result = sqlx::query!(
            "INSERT OR IGNORE INTO message_link_preview_suppressions
                 (message_id, suppressed_at) VALUES (?, ?)",
            message_id,
            now,
        )
        .execute(&self.pool)
        .await?;
        Ok(result.rows_affected() > 0)
    }

    /// The subset of `message_ids` whose previews were removed.
    pub async fn link_preview_suppressed_among(
        &self,
        message_ids: &[MessageId],
    ) -> anyhow::Result<HashSet<MessageId>> {
        if message_ids.is_empty() {
            return Ok(HashSet::new());
        }
        let mut builder = sqlx::QueryBuilder::new(
            "SELECT message_id FROM message_link_preview_suppressions WHERE message_id IN (",
        );
        let mut separated = builder.separated(", ");
        for id in message_ids {
            separated.push_bind(*id);
        }
        builder.push(")");
        use sqlx::Row;
        let mut suppressed = HashSet::new();
        for row in builder.build().fetch_all(&self.pool).await? {
            suppressed.insert(row.try_get("message_id")?);
        }
        Ok(suppressed)
    }
}
