// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Which sessions and devices an account holds live, and the cap on how many sessions that is.

use sqlx::SqliteConnection;

use super::revoke_session_rows;
use crate::ids::{DeviceId, SessionId, UserId};
use crate::store::Store;

/// The most live sessions one account holds; a sign-in past it revokes the oldest.
///
/// Push registrations live on a session's device and are cleared with it, so this caps them too.
pub(super) const MAX_LIVE_SESSIONS: i64 = 50;

/// Revokes the account's oldest live sessions past [`MAX_LIVE_SESSIONS`], returning them.
pub(super) async fn revoke_past_cap(
    conn: &mut SqliteConnection,
    user_id: UserId,
    now: i64,
) -> anyhow::Result<Vec<SessionId>> {
    let surplus = sqlx::query_scalar!(
        r#"SELECT id AS "id!: SessionId" FROM sessions
           WHERE user_id = ? AND revoked_at IS NULL
           ORDER BY created_at DESC, id DESC
           LIMIT -1 OFFSET ?"#,
        user_id,
        MAX_LIVE_SESSIONS
    )
    .fetch_all(&mut *conn)
    .await?;
    for session_id in &surplus {
        revoke_session_rows(conn, *session_id, now).await?;
    }
    Ok(surplus)
}

impl Store {
    /// The devices of this account that still hold a session nobody revoked.
    pub async fn live_device_ids(&self, user_id: UserId) -> anyhow::Result<Vec<DeviceId>> {
        Ok(sqlx::query_scalar!(
            r#"SELECT DISTINCT device_id AS "device_id!: DeviceId" FROM sessions
               WHERE user_id = ? AND revoked_at IS NULL"#,
            user_id
        )
        .fetch_all(&self.pool)
        .await?)
    }

    /// The accounts that own these sessions, each once.
    pub async fn session_owners(&self, sessions: &[SessionId]) -> anyhow::Result<Vec<UserId>> {
        if sessions.is_empty() {
            return Ok(Vec::new());
        }
        let mut builder =
            sqlx::QueryBuilder::new("SELECT DISTINCT user_id FROM sessions WHERE id IN (");
        let mut separated = builder.separated(", ");
        for id in sessions {
            separated.push_bind(*id);
        }
        builder.push(")");
        Ok(builder.build_query_scalar().fetch_all(&self.pool).await?)
    }
}
