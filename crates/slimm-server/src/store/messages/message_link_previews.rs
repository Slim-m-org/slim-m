// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Per-message link-preview suppression: a side table, never a column on
//! [`super::super::Message`]. A row means the message's cards were removed.

use std::collections::HashSet;

use crate::ids::{ChannelId, MessageId, UserId};

use super::super::{Store, now_ms};
use super::message_ops::insert_message_op;

impl Store {
    /// Records that `message_id`'s link previews were removed, and files the
    /// removal in the channel's op stream so a client that was offline learns
    /// of it from `/sync`, the way it learns of an edit. Answers the op's seq,
    /// or `None` when the removal had already happened, which writes no op.
    pub async fn suppress_link_previews(
        &self,
        channel_id: ChannelId,
        message_id: MessageId,
        actor_id: UserId,
    ) -> anyhow::Result<Option<i64>> {
        let now = now_ms();
        let mut tx = self.begin_write().await?;
        let inserted = sqlx::query!(
            "INSERT OR IGNORE INTO message_link_preview_suppressions
                 (message_id, suppressed_at) VALUES (?, ?)",
            message_id,
            now,
        )
        .execute(&mut *tx)
        .await?
        .rows_affected()
            > 0;
        let op_seq = if inserted {
            Some(
                insert_message_op(&mut tx, channel_id, message_id, "edit", Some(actor_id), now)
                    .await?,
            )
        } else {
            None
        };
        tx.commit().await?;
        Ok(op_seq)
    }

    /// Whether `message_id`'s previews were removed.
    pub async fn link_previews_suppressed(&self, message_id: MessageId) -> anyhow::Result<bool> {
        Ok(self
            .link_preview_suppressed_among(&[message_id])
            .await?
            .contains(&message_id))
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
