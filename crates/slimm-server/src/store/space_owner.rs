// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The Space owner: the one member who holds every permission, whom the role ladder exempts and
//! nobody can act on. See `docs/decisions/0092-server-hardening-review-answers.md`.

use sqlx::SqliteConnection;

use super::Store;
use crate::ids::UserId;
use crate::permissions::Permissions;

impl Store {
    /// The owner, handed on first when the stored one is no longer a member.
    pub async fn space_owner(&self) -> anyhow::Result<Option<UserId>> {
        if let Some(owner) = self.live_space_owner().await? {
            return Ok(Some(owner));
        }
        let mut tx = self.begin_write().await?;
        let owner = hand_on_owner(&mut tx).await?;
        tx.commit().await?;
        Ok(owner)
    }

    /// The stored owner while still a live human member, else `None`; never writes, so every
    /// permission read can ask it.
    pub(super) async fn live_space_owner(&self) -> anyhow::Result<Option<UserId>> {
        Ok(live_owner(&mut *self.pool.acquire().await?).await?)
    }
}

/// Keeps a live owner, else passes ownership to the earliest-joined administrator,
/// else to the earliest-joined member, and stores the answer.
pub(super) async fn hand_on_owner(conn: &mut SqliteConnection) -> sqlx::Result<Option<UserId>> {
    if let Some(owner) = live_owner(conn).await? {
        return Ok(Some(owner));
    }
    let admin_bit = Permissions::ADMINISTRATOR.bits();
    let heir = sqlx::query_scalar!(
        r#"SELECT u.id AS "id!: UserId" FROM users u
           WHERE u.deleted_at IS NULL AND u.is_bot = 0 AND u.is_webhook = 0
             AND NOT EXISTS (SELECT 1 FROM space_removals sr WHERE sr.user_id = u.id)
             AND NOT EXISTS (SELECT 1 FROM pending_members pm WHERE pm.user_id = u.id)
           ORDER BY
             CASE WHEN EXISTS (SELECT 1 FROM roles WHERE is_everyone = 1 AND (permissions & ?) != 0)
                    OR EXISTS (SELECT 1 FROM member_roles mr JOIN roles r ON r.id = mr.role_id
                               WHERE mr.user_id = u.id AND (r.permissions & ?) != 0)
                  THEN 0 ELSE 1 END,
             u.created_at, u.id
           LIMIT 1"#,
        admin_bit,
        admin_bit
    )
    .fetch_optional(&mut *conn)
    .await?;
    sqlx::query!("UPDATE space_settings SET owner_id = ? WHERE id = 1", heir)
        .execute(&mut *conn)
        .await?;
    Ok(heir)
}

/// The stored owner while they are a human still in the Space: not deleted, removed or gated.
pub(super) async fn live_owner(conn: &mut SqliteConnection) -> sqlx::Result<Option<UserId>> {
    sqlx::query_scalar!(
        r#"SELECT u.id AS "id!: UserId" FROM space_settings s JOIN users u ON u.id = s.owner_id
           WHERE s.id = 1 AND u.deleted_at IS NULL AND u.is_bot = 0 AND u.is_webhook = 0
             AND NOT EXISTS (SELECT 1 FROM space_removals sr WHERE sr.user_id = u.id)
             AND NOT EXISTS (SELECT 1 FROM pending_members pm WHERE pm.user_id = u.id)"#
    )
    .fetch_optional(&mut *conn)
    .await
}
