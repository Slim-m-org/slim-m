// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Persistence for `message_mentions`: who a message mentions, resolved once
//! at send or edit time by [`crate::mentions::mentioned_viewers`] and read
//! back per caller. See migration 0061 for why this is a side table rather
//! than a column on `messages`.

use std::collections::{HashMap, HashSet};

use sqlx::QueryBuilder;

use super::super::Store;
use crate::ids::{ChannelId, MessageId, UserId};

impl Store {
    /// Replaces `message_id`'s whole mention set. Delete-then-insert rather
    /// than a diff: the set is small (at most a channel's viewer count) and
    /// this is called at most once per send and once per content-changing
    /// edit, never per read. `direct` are the ones named by a plain `@username`
    /// outside code (see `push::recipients::directly_named`), for search's `mentions:`.
    pub async fn set_message_mentions(
        &self,
        message_id: MessageId,
        mentioned: &[UserId],
        reply_ping: Option<UserId>,
        direct: &[UserId],
    ) -> anyhow::Result<()> {
        // Nothing to clear or write is the ordinary send; skip the write gate's turn.
        if mentioned.is_empty() && !self.has_stored_mentions(message_id).await? {
            return Ok(());
        }
        let mut tx = self.begin_write().await?;
        sqlx::query!(
            "DELETE FROM message_mentions WHERE message_id = ?",
            message_id
        )
        .execute(&mut *tx)
        .await?;
        for user_id in mentioned {
            let via_reply = reply_ping == Some(*user_id);
            let is_direct = direct.contains(user_id);
            sqlx::query!(
                "INSERT INTO message_mentions (user_id, message_id, via_reply, direct) \
                 VALUES (?, ?, ?, ?)",
                user_id,
                message_id,
                via_reply,
                is_direct
            )
            .execute(&mut *tx)
            .await?;
        }
        tx.commit().await?;
        Ok(())
    }

    async fn has_stored_mentions(&self, message_id: MessageId) -> anyhow::Result<bool> {
        Ok(sqlx::query_scalar::<_, bool>(
            "SELECT EXISTS(SELECT 1 FROM message_mentions WHERE message_id = ?)",
        )
        .bind(message_id)
        .fetch_one(&self.pool)
        .await?)
    }

    /// Which of `message_ids` mention `viewer`, for `MessageDto::mentions_me`.
    /// The batched sibling of [`Self::is_mentioned`], read by
    /// `http::message_enrich::with_reactions` alongside reactions,
    /// attachments and threads rather than once per row.
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

    /// The seq of the newest live message mentioning `viewer` in each of `channel_ids`.
    /// A channel with none is absent, and callers read it as 0, the client's own "no mention".
    pub async fn newest_mentions_for(
        &self,
        viewer: UserId,
        channel_ids: &[ChannelId],
    ) -> anyhow::Result<HashMap<ChannelId, i64>> {
        use sqlx::Row;

        let mut newest = HashMap::new();
        for chunk in channel_ids.chunks(super::super::MAX_IDS_PER_QUERY - 1) {
            // CROSS JOIN pins the viewer's own rows as the outer loop; one channel otherwise scans all of its messages.
            let mut builder = QueryBuilder::new(
                "SELECT m.channel_id, MAX(m.seq) AS seq FROM message_mentions mm \
                 CROSS JOIN messages m ON m.id = mm.message_id \
                 WHERE mm.user_id = ",
            );
            builder.push_bind(viewer);
            builder.push(" AND m.deleted_at IS NULL AND m.channel_id IN (");
            let mut separated = builder.separated(", ");
            for id in chunk {
                separated.push_bind(*id);
            }
            builder.push(") GROUP BY m.channel_id");
            for row in builder.build().fetch_all(&self.pool).await? {
                newest.insert(row.try_get("channel_id")?, row.try_get("seq")?);
            }
        }
        Ok(newest)
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

    /// The author of `message_id` when they could be pinged by a reply: a
    /// live account that is not a webhook. `None` for a webhook, a deleted
    /// account or an anonymized message.
    pub async fn reply_ping_candidate(
        &self,
        message_id: MessageId,
    ) -> anyhow::Result<Option<UserId>> {
        let author = sqlx::query_scalar!(
            r#"SELECT m.author_id AS "author_id!: UserId"
               FROM messages m JOIN users u ON u.id = m.author_id
               WHERE m.id = ? AND u.deleted_at IS NULL AND u.is_webhook = 0"#,
            message_id
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(author)
    }

    /// Who `message_id`'s reply pinged, if its send stored a ping and they
    /// are still a live account.
    pub async fn reply_pinged(&self, message_id: MessageId) -> anyhow::Result<Option<UserId>> {
        let pinged = sqlx::query_scalar!(
            r#"SELECT mm.user_id AS "user_id!: UserId"
               FROM message_mentions mm JOIN users u ON u.id = mm.user_id
               WHERE mm.message_id = ? AND mm.via_reply = 1 AND u.deleted_at IS NULL"#,
            message_id
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(pinged)
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
