// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Persistence for the one durable notification choice: how much of a
//! channel's traffic is worth waking a device for. Read singly by
//! `GET /push/preference` and in batch by push fan-out
//! (`push::recipients::message_recipients`), which is the only place it is
//! ever enforced.

use std::collections::HashMap;

use sqlx::QueryBuilder;

use super::Store;
use crate::ids::{ChannelId, UserId};
use crate::notifications::NotificationPreference;

impl Store {
    /// The preference a live user has chosen, or `None` if the account is
    /// gone (deleted or never existed) -- the same "answers like an id that
    /// was never used" contract every other profile read in this crate
    /// follows.
    ///
    /// An unparseable stored value defaults to
    /// [`NotificationPreference::Everything`] rather than failing the
    /// request: this column is only ever written through
    /// [`Store::set_notification_preference`], which only accepts
    /// [`NotificationPreference::as_str`] spellings, so this should not
    /// happen, and a notification preference is not worth an internal error
    /// over.
    pub async fn notification_preference(
        &self,
        user_id: UserId,
    ) -> anyhow::Result<Option<NotificationPreference>> {
        let row = sqlx::query!(
            r#"SELECT notification_preference AS "notification_preference!" FROM users
               WHERE id = ? AND deleted_at IS NULL"#,
            user_id
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(row
            .map(|r| NotificationPreference::parse(&r.notification_preference).unwrap_or_default()))
    }

    /// Sets the caller's preference. Returns `false` if the account is gone,
    /// the same tiny concurrent-deletion window documented on
    /// [`Store::update_profile`](super::Store::update_profile).
    pub async fn set_notification_preference(
        &self,
        user_id: UserId,
        preference: NotificationPreference,
    ) -> anyhow::Result<bool> {
        let value = preference.as_str();
        let affected = sqlx::query!(
            "UPDATE users SET notification_preference = ? WHERE id = ? AND deleted_at IS NULL",
            value,
            user_id
        )
        .execute(&self.pool)
        .await?
        .rows_affected();
        Ok(affected > 0)
    }

    /// Batched read for push fan-out: one query for however many recipients
    /// survived view and thread narrowing, the [`Store::roles_for_users`]
    /// shape rather than one lookup per candidate. An id absent from the
    /// map (deleted mid-fan-out) is read as the default at the call site,
    /// the same contract [`Store::notification_preference`] has for one id.
    pub async fn notification_preferences(
        &self,
        user_ids: &[UserId],
    ) -> anyhow::Result<HashMap<UserId, NotificationPreference>> {
        if user_ids.is_empty() {
            return Ok(HashMap::new());
        }

        // Built, not a fixed `query!`: the id list is variable length; see `user_profiles`.
        let mut builder = QueryBuilder::new(
            "SELECT id, notification_preference FROM users \
             WHERE deleted_at IS NULL AND id IN (",
        );
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
            let raw: String = row.try_get("notification_preference")?;
            preferences.insert(id, NotificationPreference::parse(&raw).unwrap_or_default());
        }
        Ok(preferences)
    }

    /// Whether `channel_id` should notify a [`NotificationPreference::Mentions`]
    /// recipient the same way an actual mention would: true for a DM, since
    /// somebody messaging this account there is addressing them directly by
    /// definition.
    ///
    /// Resolved through [`Store::permission_channel`], the same one-hop
    /// thread-to-parent resolution every other permission-shaped check in
    /// this crate already uses, so a reply inside a thread hung off a DM
    /// message counts too. CLAUDE.md's "Moderation reaching only the
    /// channel kind it was written for" names this exact bug shape - a
    /// `kind == dm` check that skips the thread hop - as one this project
    /// has shipped twice already; reusing the resolution rather than reading
    /// `channel_id`'s own `kind` is what keeps this from being a third time.
    pub async fn channel_notifies_as_dm(&self, channel_id: ChannelId) -> anyhow::Result<bool> {
        let Some(channel) = self.channel(channel_id).await? else {
            return Ok(false);
        };
        let Some(resolved) = self.permission_channel(channel).await? else {
            return Ok(false);
        };
        Ok(resolved.kind == super::dms::DM_CHANNEL_KIND)
    }
}
