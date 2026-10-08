// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Persistence for `message_mentions`: who a message mentions, resolved once
//! at send or edit time by [`crate::mentions::mentioned_viewers`] and read
//! back per caller. See migration 0061 for why this is a side table rather
//! than a column on `messages`.

use std::collections::HashSet;

use sqlx::QueryBuilder;

use super::Store;
use crate::ids::{MessageId, UserId};

impl Store {
    /// Replaces `message_id`'s whole mention set. Delete-then-insert rather
    /// than a diff: the set is small (at most a channel's viewer count) and
    /// this is called at most once per send and once per content-changing
    /// edit, never per read.
    pub async fn set_message_mentions(
        &self,
        message_id: MessageId,
        mentioned: &[UserId],
    ) -> anyhow::Result<()> {
        let mut tx = self.begin_write().await?;
        sqlx::query!(
            "DELETE FROM message_mentions WHERE message_id = ?",
            message_id
        )
        .execute(&mut *tx)
        .await?;
        for user_id in mentioned {
            sqlx::query!(
                "INSERT INTO message_mentions (user_id, message_id) VALUES (?, ?)",
                user_id,
                message_id
            )
            .execute(&mut *tx)
            .await?;
        }
        tx.commit().await?;
        Ok(())
    }

    /// Which of `message_ids` mention `viewer`, for [`MessageDto::mentions_me`].
    /// The batched sibling of [`Self::is_mentioned`], read by
    /// `http::message_enrich::with_reactions` alongside reactions,
    /// attachments and threads rather than once per row.
    ///
    /// [`MessageDto::mentions_me`]: crate::http::messages::MessageDto
    pub async fn mentioned_messages_for(
        &self,
        viewer: UserId,
        message_ids: &[MessageId],
    ) -> anyhow::Result<HashSet<MessageId>> {
        if message_ids.is_empty() {
            return Ok(HashSet::new());
        }
        let mut builder =
            QueryBuilder::new("SELECT message_id FROM message_mentions WHERE user_id = ");
        builder.push_bind(viewer);
        builder.push(" AND message_id IN (");
        let mut separated = builder.separated(", ");
        for id in message_ids {
            separated.push_bind(*id);
        }
        builder.push(")");

        use sqlx::Row;
        let rows = builder.build().fetch_all(&self.pool).await?;
        rows.into_iter()
            .map(|row| {
                row.try_get::<MessageId, _>("message_id")
                    .map_err(Into::into)
            })
            .collect()
    }

    /// Everyone `message_id` mentions, for the live path to resolve once per
    /// message rather than once per connection (see `hub::CreatedLookups`).
    pub async fn mentioned_user_ids(
        &self,
        message_id: MessageId,
    ) -> anyhow::Result<std::collections::HashSet<UserId>> {
        let ids = sqlx::query_scalar!(
            r#"SELECT user_id AS "user_id: UserId" FROM message_mentions WHERE message_id = ?"#,
            message_id
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(ids.into_iter().collect())
    }

    /// Whether `message_id` mentions `user_id` - the live path's own point
    /// lookup, run once per connection a `message.created`/`message.edited`
    /// frame reaches, since the hub broadcast carries no per-viewer field for
    /// it to read instead (see `http::ws::authorization`).
    pub async fn is_mentioned(
        &self,
        message_id: MessageId,
        user_id: UserId,
    ) -> anyhow::Result<bool> {
        let found = sqlx::query_scalar!(
            r#"SELECT EXISTS(
                   SELECT 1 FROM message_mentions WHERE message_id = ? AND user_id = ?
               ) AS "found!: bool""#,
            message_id,
            user_id
        )
        .fetch_one(&self.pool)
        .await?;
        Ok(found)
    }
}
