// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The member a bot's message quotes or re-posts, so blocks cover the repost.

use std::collections::HashMap;

use sqlx::Row;

use crate::ids::{MessageId, UserId};
use crate::store::{MAX_IDS_PER_QUERY, Store};

impl Store {
    /// Whether `user_id` is a live person, the only kind a repost may name.
    pub async fn is_live_person(&self, user_id: UserId) -> anyhow::Result<bool> {
        let found = sqlx::query(
            "SELECT 1 FROM users WHERE id = ? AND deleted_at IS NULL AND is_bot = 0 AND is_webhook = 0",
        )
        .bind(user_id)
        .fetch_optional(&self.pool)
        .await?;
        Ok(found.is_some())
    }

    /// Records whose words `message_id` re-posts. Written once, with the message.
    pub async fn set_repost_author(
        &self,
        message_id: MessageId,
        author_id: UserId,
    ) -> anyhow::Result<()> {
        sqlx::query(
            "INSERT OR IGNORE INTO message_repost_authors (message_id, author_id) VALUES (?, ?)",
        )
        .bind(message_id)
        .bind(author_id)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// The member `message_id` re-posts, or `None`. The live frames and push read it per message.
    pub async fn repost_author(&self, message_id: MessageId) -> anyhow::Result<Option<UserId>> {
        let row = sqlx::query("SELECT author_id FROM message_repost_authors WHERE message_id = ?")
            .bind(message_id)
            .fetch_optional(&self.pool)
            .await?;
        Ok(row.map(|r| r.try_get("author_id")).transpose()?)
    }

    /// The re-posted member of each of `message_ids` that has one; list, search and sync use this.
    pub async fn repost_authors_for_messages(
        &self,
        message_ids: &[MessageId],
    ) -> anyhow::Result<HashMap<MessageId, UserId>> {
        let mut authors = HashMap::new();
        for chunk in message_ids.chunks(MAX_IDS_PER_QUERY) {
            let mut builder = sqlx::QueryBuilder::new(
                "SELECT message_id, author_id FROM message_repost_authors WHERE message_id IN (",
            );
            let mut separated = builder.separated(", ");
            for id in chunk {
                separated.push_bind(*id);
            }
            builder.push(")");
            for row in builder.build().fetch_all(&self.pool).await? {
                authors.insert(row.try_get("message_id")?, row.try_get("author_id")?);
            }
        }
        Ok(authors)
    }
}
