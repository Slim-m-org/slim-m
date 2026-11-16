// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The Space owner: the one member who holds every permission, whom the role ladder exempts and
//! nobody can act on. See `docs/decisions/0092-server-hardening-review-answers.md`.

use sqlx::SqliteConnection;

use super::{Store, now_ms};
use crate::ids::UserId;
use crate::permissions::Permissions;

/// Who owns the Space, and the hand-off that finding out made, for the caller to announce.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Ownership {
    pub owner: Option<UserId>,
    pub handoff: Option<Handoff>,
}

/// Ownership just passed to `heir`, ending any timeout on them, since nobody could lift it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Handoff {
    pub heir: UserId,
    pub lifted_timeout: bool,
}

impl Store {
    /// The stored owner while still a live human member, else `None`; never writes, so every
    /// permission read can ask it.
    pub async fn space_owner(&self) -> anyhow::Result<Option<UserId>> {
        Ok(live_owner(&mut *self.pool.acquire().await?).await?)
    }

    /// [`Self::space_owner`], handing ownership on first when the stored one is no longer a member.
    pub async fn settle_space_owner(&self) -> anyhow::Result<Ownership> {
        if let Some(owner) = self.space_owner().await? {
            return Ok(Ownership {
                owner: Some(owner),
                handoff: None,
            });
        }
        let mut tx = self.begin_write().await?;
        let ownership = hand_on_owner(&mut tx).await?;
        tx.commit().await?;
        Ok(ownership)
    }
}

/// Keeps a live owner, else passes ownership to the earliest-joined administrator,
/// else to the earliest-joined member, and stores the answer.
pub(super) async fn hand_on_owner(conn: &mut SqliteConnection) -> sqlx::Result<Ownership> {
    if let Some(owner) = live_owner(conn).await? {
        return Ok(Ownership {
            owner: Some(owner),
            handoff: None,
        });
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
    let handoff = match heir {
        Some(heir) => Some(Handoff {
            heir,
            lifted_timeout: end_timeout(conn, heir).await?,
        }),
        None => None,
    };
    Ok(Ownership {
        owner: heir,
        handoff,
    })
}

/// Deletes `user_id`'s timeout row, answering whether it was still in force.
async fn end_timeout(conn: &mut SqliteConnection, user_id: UserId) -> sqlx::Result<bool> {
    let until = sqlx::query_scalar!(
        "DELETE FROM member_timeouts WHERE user_id = ? RETURNING until",
        user_id
    )
    .fetch_optional(&mut *conn)
    .await?;
    Ok(until.is_some_and(|until| until > now_ms()))
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
