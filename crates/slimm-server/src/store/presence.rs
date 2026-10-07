// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Persistence for the one durable piece of presence: a user's chosen
//! visibility. Everything else about presence (whether they are actually
//! connected right now) is in-memory only; see [`crate::presence`].

use std::collections::HashMap;

use sqlx::{QueryBuilder, Row};

use super::Store;
use crate::ids::{DeviceId, UserId};
use crate::presence::{DeviceKind, Visibility};

impl Store {
    /// The visibility a live user has chosen, or `None` if the account is
    /// gone (deleted or never existed) -- the same "answers like an id that
    /// was never used" contract every other profile read in this crate
    /// follows.
    ///
    /// An unparseable stored value defaults to `Online` rather than failing
    /// the request: this column is only ever written through
    /// [`Store::set_presence_visibility`], which only accepts
    /// [`Visibility::as_str`] spellings, so this should not happen, and
    /// presence is not worth an internal error over.
    pub async fn presence_visibility(&self, user_id: UserId) -> anyhow::Result<Option<Visibility>> {
        let row = sqlx::query!(
            r#"SELECT presence_visibility AS "presence_visibility!" FROM users
               WHERE id = ? AND deleted_at IS NULL"#,
            user_id
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.map(|r| Visibility::parse(&r.presence_visibility).unwrap_or_default()))
    }

    /// The kind of client a device signed in as, for presence. Unknown on any
    /// failure or a session older than the column: presence is not worth an
    /// error over a label.
    pub async fn device_kind(&self, device_id: DeviceId) -> DeviceKind {
        let kind: Option<Option<String>> =
            sqlx::query_scalar("SELECT client_kind FROM devices WHERE id = ?")
                .bind(device_id)
                .fetch_optional(&self.pool)
                .await
                .unwrap_or(None);
        DeviceKind::from_client_kind(kind.flatten().as_deref())
    }

    /// [`Self::presence_visibility`] for several users in one query, mirroring
    /// [`Self::reactions_for_messages`](super::Store::reactions_for_messages)'s
    /// built `IN (...)` for the same "one round trip per page, not one per
    /// row" shape.
    ///
    /// An id with no live row (deleted or never existed) is simply absent
    /// from the map, the same "skip it" contract the per-id callers already
    /// had: `GET /presence` drops it from the response, and voice roster
    /// treats it as visible since there is nothing to hide.
    pub async fn presence_visibility_many(
        &self,
        ids: &[UserId],
    ) -> anyhow::Result<HashMap<UserId, Visibility>> {
        let mut result = HashMap::with_capacity(ids.len());
        if ids.is_empty() {
            return Ok(result);
        }

        let mut builder = QueryBuilder::new(
            "SELECT id, presence_visibility FROM users WHERE deleted_at IS NULL AND id IN (",
        );
        let mut separated = builder.separated(", ");
        for id in ids {
            separated.push_bind(*id);
        }
        builder.push(")");

        let rows = builder.build().fetch_all(&self.pool).await?;
        for row in rows {
            let id: UserId = row.try_get("id")?;
            let raw: String = row.try_get("presence_visibility")?;
            result.insert(id, Visibility::parse(&raw).unwrap_or_default());
        }
        Ok(result)
    }

    /// Sets the caller's visibility preference. Returns `false` if the
    /// account is gone, the same tiny concurrent-deletion window documented
    /// on [`Store::update_profile`](super::Store::update_profile).
    pub async fn set_presence_visibility(
        &self,
        user_id: UserId,
        visibility: Visibility,
    ) -> anyhow::Result<bool> {
        let value = visibility.as_str();
        let affected = sqlx::query!(
            "UPDATE users SET presence_visibility = ? WHERE id = ? AND deleted_at IS NULL",
            value,
            user_id
        )
        .execute(&self.pool)
        .await?
        .rows_affected();
        Ok(affected > 0)
    }
}
