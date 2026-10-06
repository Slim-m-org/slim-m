// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Persistence for a per-(user, channel) override of the account-wide
//! notification preference (`store/notifications.rs`).
//!
//! Read singly nowhere: the effective answer push fan-out cares about is
//! resolved in one query, [`Store::channel_notification_preferences`], which
//! `COALESCE`s a channel's own override over the account default rather than
//! two round trips - the choke point `notifications.rs`'s own doc comment
//! already names as where a future per-channel table would resolve. Read in
//! bulk by `GET /notification-preferences/channels` for the caller's own
//! settings screen and rail glyphs.

use std::collections::HashMap;

use sqlx::QueryBuilder;

use super::{Store, now_ms};
use crate::ids::{ChannelId, UserId};
use crate::notifications::NotificationPreference;

impl Store {
    /// Sets or replaces `user_id`'s override for `channel_id`. `preference`
    /// is never [`NotificationPreference::Everything`] in practice - the
    /// HTTP layer refuses to store it, since having no row already means
    /// that - but nothing here depends on that refusal for correctness.
    pub async fn set_channel_notification_preference(
        &self,
        user_id: UserId,
        channel_id: ChannelId,
        preference: NotificationPreference,
    ) -> anyhow::Result<()> {
        let value = preference.as_str();
        let now = now_ms();
        sqlx::query!(
            "INSERT INTO channel_notification_prefs (user_id, channel_id, preference, updated_at)
             VALUES (?, ?, ?, ?)
             ON CONFLICT (user_id, channel_id)
             DO UPDATE SET preference = excluded.preference, updated_at = excluded.updated_at",
            user_id,
            channel_id,
            value,
            now,
        )
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// Clears `user_id`'s override for `channel_id`, reverting the channel
    /// to the account default. Idempotent: clearing an override that never
    /// existed, or a channel that no longer does, is not an error.
    pub async fn clear_channel_notification_preference(
        &self,
        user_id: UserId,
        channel_id: ChannelId,
    ) -> anyhow::Result<()> {
        sqlx::query!(
            "DELETE FROM channel_notification_prefs WHERE user_id = ? AND channel_id = ?",
            user_id,
            channel_id,
        )
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// `user_id`'s own override for `channel_id`, or `None` when the channel
    /// is following the account default - never [`NotificationPreference::Everything`]
    /// in practice, for the same reason [`Store::set_channel_notification_preference`]
    /// never writes it.
    pub async fn channel_notification_preference(
        &self,
        user_id: UserId,
        channel_id: ChannelId,
    ) -> anyhow::Result<Option<NotificationPreference>> {
        let row = sqlx::query!(
            "SELECT preference FROM channel_notification_prefs
             WHERE user_id = ? AND channel_id = ?",
            user_id,
            channel_id,
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.map(|r| NotificationPreference::parse(&r.preference).unwrap_or_default()))
    }

    /// Every channel `user_id` has overridden, for their own settings screen
    /// and the rail's muted glyph - a channel following the account default
    /// carries no row and is absent here, never listed at `everything`.
    pub async fn list_channel_notification_preferences(
        &self,
        user_id: UserId,
    ) -> anyhow::Result<Vec<(ChannelId, NotificationPreference)>> {
        let rows = sqlx::query!(
            r#"SELECT channel_id AS "channel_id: ChannelId", preference
               FROM channel_notification_prefs WHERE user_id = ?"#,
            user_id,
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .into_iter()
            .map(|r| {
                (
                    r.channel_id,
                    NotificationPreference::parse(&r.preference).unwrap_or_default(),
                )
            })
            .collect())
    }

    /// The effective preference for each of `user_ids` in `channel_id`: that
    /// user's own override for this channel if they have set one, else the one
    /// they set on `parent_channel_id`, else their account default - one query
    /// rather than a preference lookup plus a second one, the batched shape [`Store::roles_for_users`] already uses. An id absent
    /// from the map (deleted mid-fan-out) is read as the default at the call
    /// site, the same contract every sibling batched lookup in this crate
    /// follows.
    ///
    /// `parent_channel_id` is a thread's parent channel, and `None` for every
    /// other channel. A thread is its own channel row, so without that second
    /// step muting a channel would only mute the part of the conversation that
    /// nobody replied to in a thread; the thread's own override still wins
    /// when one exists, since it is the more specific answer.
    ///
    /// This is the one place [`crate::push::recipients::narrow_for_notification_preference`]
    /// reads a preference from, replacing the account-only lookup it used
    /// before a channel override existed to consult.
    pub async fn channel_notification_preferences(
        &self,
        channel_id: ChannelId,
        parent_channel_id: Option<ChannelId>,
        user_ids: &[UserId],
    ) -> anyhow::Result<HashMap<UserId, NotificationPreference>> {
        if user_ids.is_empty() {
            return Ok(HashMap::new());
        }

        // Built, not a fixed `query!`: the id list is variable length; see `user_profiles`.
        let mut builder = QueryBuilder::new(
            "SELECT u.id AS id, \
             COALESCE(c.preference, p.preference, u.notification_preference) AS preference \
             FROM users u LEFT JOIN channel_notification_prefs c \
             ON c.user_id = u.id AND c.channel_id = ",
        );
        builder.push_bind(channel_id);
        builder.push(
            " LEFT JOIN channel_notification_prefs p ON p.user_id = u.id AND p.channel_id = ",
        );
        builder.push_bind(parent_channel_id);
        builder.push(" WHERE u.deleted_at IS NULL AND u.id IN (");
        let mut separated = builder.separated(", ");
        for id in user_ids {
            separated.push_bind(*id);
        }
        builder.push(")");

        let rows = builder.build().fetch_all(&self.pool).await?;
        use sqlx::Row;
        let mut preferences = HashMap::with_capacity(rows.len());
        for row in rows {
            let id: UserId = row.try_get("id")?;
            let raw: String = row.try_get("preference")?;
            preferences.insert(id, NotificationPreference::parse(&raw).unwrap_or_default());
        }
        Ok(preferences)
    }
}
