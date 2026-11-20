// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Deciding `message_mentions.direct` for rows written before migration 0203,
//! which only the mention grammar can, so a startup sweep does it in batches.

use super::super::Store;
use crate::ids::{MessageId, UserId};

impl Store {
    /// Up to `limit` messages that still have a mention row with `direct` undecided, with their text.
    pub async fn undecided_mention_messages(
        &self,
        limit: i64,
    ) -> anyhow::Result<Vec<(MessageId, String)>> {
        let rows = sqlx::query!(
            r#"SELECT m.id AS "id!: MessageId", m.content AS "content!"
               FROM messages m
               WHERE m.id IN (SELECT DISTINCT message_id FROM message_mentions
                              WHERE direct IS NULL LIMIT ?)"#,
            limit
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows.into_iter().map(|r| (r.id, r.content)).collect())
    }

    /// Decides every mention row of `message_id`: direct for the accounts in `direct`, not for the rest.
    pub async fn decide_mention_directness(
        &self,
        message_id: MessageId,
        direct: &[UserId],
    ) -> anyhow::Result<()> {
        let mut tx = self.begin_write().await?;
        sqlx::query!(
            "UPDATE message_mentions SET direct = 0 WHERE message_id = ?",
            message_id
        )
        .execute(&mut *tx)
        .await?;
        for user_id in direct {
            sqlx::query!(
                "UPDATE message_mentions SET direct = 1 WHERE message_id = ? AND user_id = ?",
                message_id,
                user_id
            )
            .execute(&mut *tx)
            .await?;
        }
        tx.commit().await?;
        Ok(())
    }

    /// Decides every undecided mention row, a batch at a time; returns how many messages it read.
    pub async fn backfill_mention_directness(&self) -> anyhow::Result<usize> {
        const BATCH: i64 = 200;
        let mut decided = 0;
        loop {
            let batch = self.undecided_mention_messages(BATCH).await?;
            if batch.is_empty() {
                return Ok(decided);
            }
            for (message_id, content) in batch {
                let named = crate::push::recipients::directly_named(&content);
                let direct = self.user_ids_for_usernames(&named).await?;
                self.decide_mention_directness(message_id, &direct).await?;
                decided += 1;
            }
        }
    }
}
