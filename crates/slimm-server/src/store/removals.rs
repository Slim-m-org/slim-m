// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Removing somebody from the Space, and letting them back in.
//!
//! There is no membership row to delete - one deployment is one community and
//! holding an account *is* membership - so a removal is a standing refusal
//! recorded against the account: live sessions are torn down, sign-in stops
//! working, and the member list stops listing them.
//!
//! What is deliberately left alone is everything they wrote. Removing a
//! person is not a reason to rewrite a conversation other people were part
//! of, so no authorship join learns about this table; anonymizing content is
//! [`Store::delete_account`]'s job and stays a separate, heavier act that the
//! account's own holder or an administrator chooses on purpose.

use sqlx::SqliteConnection;

use super::moderation_audit::{ModerationAudit, record_moderation_audit};
use super::roles::administrator_count;
use super::sessions::revoke_session_rows;
use super::{Store, now_ms};
use crate::ids::{SessionId, UserId};

/// A removal in force, for the administration screen that reverses it.
#[derive(Debug, Clone)]
pub struct SpaceRemoval {
    pub user_id: UserId,
    pub username: String,
    pub display_name: String,
    pub reason: Option<String>,
    /// Null once the removing moderator's own account is deleted.
    pub removed_by: Option<UserId>,
    pub removed_at: i64,
    /// The invite this member registered through, or `None` if they had
    /// none - a ban-evasion signal for whoever is reviewing this list; see
    /// MOD9. `/members/removed` already requires BAN_MEMBERS, so this is
    /// never gated further.
    pub invite_code: Option<String>,
}

/// Why a removal was refused.
#[derive(Debug)]
pub enum RemoveMemberError {
    /// The account does not exist, or has already been deleted.
    UserNotFound,
    /// Removing them would leave a deployment nobody can administer.
    LastAdministrator,
    Internal(anyhow::Error),
}

impl From<sqlx::Error> for RemoveMemberError {
    fn from(err: sqlx::Error) -> Self {
        RemoveMemberError::Internal(err.into())
    }
}

impl From<anyhow::Error> for RemoveMemberError {
    fn from(err: anyhow::Error) -> Self {
        RemoveMemberError::Internal(err)
    }
}

impl Store {
    /// Removes a member and tears down their live access, returning the
    /// sessions that were revoked so the caller can close those sockets.
    ///
    /// Write-first under `BEGIN IMMEDIATE`, so a sign-in racing this
    /// serializes against it the same way one racing an account deletion
    /// does: [`Store::open_session`]'s device insert is conditional on there
    /// being no removal row, and whichever of the two commits first wins.
    ///
    /// Idempotent on a member already removed - the row is replaced, which
    /// also re-revokes anything that somehow reappeared.
    ///
    /// Refuses to remove the last administrator, for the reason
    /// [`Store::delete_account`] gives: roles, invites and moderation all need
    /// a bit that no reachable account would hold afterwards.
    pub async fn remove_from_space(
        &self,
        user_id: UserId,
        removed_by: UserId,
        reason: Option<&str>,
    ) -> Result<Vec<SessionId>, RemoveMemberError> {
        let now = now_ms();
        let mut tx = self.begin_write().await?;
        let revoked = remove_one(&mut tx, user_id, removed_by, reason, now).await?;
        tx.commit().await?;
        Ok(revoked)
    }

    /// Lets a removed member back in. `false` if they were not removed.
    ///
    /// A human's sessions stay revoked: readmission restores the right to
    /// sign in, not the credentials on whatever devices were signed in at the
    /// time. That reasoning is vacuous for a bot, which has no sign-in to
    /// retry - its token *is* its only credential, so leaving its session
    /// revoked would make restoring it a member-list fiction that still
    /// 401s on the next request. So a bot's session is the one exception: if
    /// it still backs a live (non-revoked) `bot_tokens` row, restoring
    /// un-revokes it too. A token an admin revoked before the removal stays
    /// dead, because that row's `revoked_at` is already set and the join
    /// below excludes it - restoring reverses the removal, not an earlier,
    /// unrelated revocation.
    ///
    /// Deleting the row is what lifts the removal, so the act itself is only
    /// recorded in `moderation_audit_log` - and only when there was something
    /// to lift, since restoring somebody who was never removed did nothing.
    pub async fn restore_to_space(
        &self,
        user_id: UserId,
        restored_by: UserId,
    ) -> anyhow::Result<bool> {
        let now = now_ms();
        let mut tx = self.begin_write().await?;

        let restored = sqlx::query!("DELETE FROM space_removals WHERE user_id = ?", user_id)
            .execute(&mut *tx)
            .await?
            .rows_affected()
            > 0;
        if restored {
            unrevoke_live_bot_session(&mut tx, user_id).await?;
            record_moderation_audit(
                &mut tx,
                ModerationAudit {
                    actor_id: restored_by,
                    subject_id: user_id,
                    action: "restore",
                    reason: None,
                    until: None,
                    created_at: now,
                },
            )
            .await?;
        }

        tx.commit().await?;
        Ok(restored)
    }

    /// Every removal in force, newest first, with enough identity to show a
    /// row for somebody the member list deliberately no longer carries.
    pub async fn list_removals(&self) -> anyhow::Result<Vec<SpaceRemoval>> {
        let rows = sqlx::query!(
            r#"SELECT r.user_id AS "user_id!: UserId", u.username, u.display_name,
                      r.reason, r.removed_by AS "removed_by?: UserId", r.removed_at
               FROM space_removals r
               JOIN users u ON u.id = r.user_id
               WHERE u.deleted_at IS NULL
               ORDER BY r.removed_at DESC"#
        )
        .fetch_all(&self.pool)
        .await?;
        let ids: Vec<UserId> = rows.iter().map(|r| r.user_id).collect();
        let invite_codes = self.registration_invite_codes(&ids).await?;
        Ok(rows
            .into_iter()
            .map(|r| SpaceRemoval {
                invite_code: invite_codes.get(&r.user_id).cloned(),
                user_id: r.user_id,
                username: r.username,
                display_name: r.display_name,
                reason: r.reason,
                removed_by: r.removed_by,
                removed_at: r.removed_at,
            })
            .collect())
    }
}

/// The removal check, on a connection, so the login path can run it inside
/// the transaction it already holds.
pub(super) async fn removed(
    conn: &mut SqliteConnection,
    user_id: UserId,
) -> Result<bool, sqlx::Error> {
    Ok(sqlx::query_scalar!(
        r#"SELECT 1 AS "one!: i64" FROM space_removals WHERE user_id = ?"#,
        user_id
    )
    .fetch_optional(&mut *conn)
    .await?
    .is_some())
}

/// Un-revokes the session behind `user_id`'s live bot token, if it is a bot
/// and has one.
///
/// Scoped by joining on `bot_tokens.revoked_at IS NULL`, so this only ever
/// touches the one session an active bot token still points at - never a
/// human's session, and never a bot session whose token was independently
/// revoked before the removal it is now being lifted from. A no-op for a
/// human, and for a bot with no live token, since the `UPDATE` then matches
/// nothing.
async fn unrevoke_live_bot_session(
    tx: &mut SqliteConnection,
    user_id: UserId,
) -> Result<(), sqlx::Error> {
    sqlx::query!(
        "UPDATE sessions SET revoked_at = NULL
         WHERE revoked_at IS NOT NULL
           AND id IN (
             SELECT session_id FROM bot_tokens
             WHERE bot_user_id = ? AND revoked_at IS NULL
           )",
        user_id
    )
    .execute(&mut *tx)
    .await?;
    Ok(())
}

/// One removal, inside a transaction the caller owns.
///
/// Split out so the bulk path in [`super::members_bulk`] runs exactly this and
/// not a second implementation of it. A bulk verb that forgot the invite
/// revocation, or the session teardown, or the audit row, would be a quieter
/// removal than the single one for no reason a reader could find.
///
/// The last-administrator check sits after the insert on purpose, so a batch
/// removing every remaining administrator refuses as a whole rather than
/// leaving the deployment to whichever one happened to be last in the list.
pub(super) async fn remove_one(
    tx: &mut SqliteConnection,
    user_id: UserId,
    removed_by: UserId,
    reason: Option<&str>,
    now: i64,
) -> Result<Vec<SessionId>, RemoveMemberError> {
    let exists = sqlx::query_scalar!(
        r#"SELECT 1 AS "one!: i64" FROM users WHERE id = ? AND deleted_at IS NULL"#,
        user_id
    )
    .fetch_optional(&mut *tx)
    .await?;
    if exists.is_none() {
        return Err(RemoveMemberError::UserNotFound);
    }

    sqlx::query!(
        "INSERT INTO space_removals (user_id, reason, removed_by, removed_at)
         VALUES (?, ?, ?, ?)
         ON CONFLICT(user_id) DO UPDATE SET
             reason = excluded.reason,
             removed_by = excluded.removed_by,
             removed_at = excluded.removed_at",
        user_id,
        reason,
        removed_by,
        now
    )
    .execute(&mut *tx)
    .await?;

    if administrator_count(tx).await? == 0 {
        return Err(RemoveMemberError::LastAdministrator);
    }

    let revoked: Vec<SessionId> = sqlx::query!(
        r#"SELECT id AS "id!: SessionId" FROM sessions
           WHERE user_id = ? AND revoked_at IS NULL"#,
        user_id
    )
    .fetch_all(&mut *tx)
    .await?
    .into_iter()
    .map(|row| row.id)
    .collect();
    for session_id in &revoked {
        revoke_session_rows(tx, *session_id, now).await?;
    }

    // Their unspent invites go too, or a removal hands out the way back in.
    sqlx::query!(
        "UPDATE invites SET revoked_at = ? WHERE created_by = ? AND revoked_at IS NULL",
        now,
        user_id
    )
    .execute(&mut *tx)
    .await?;

    record_moderation_audit(
        tx,
        ModerationAudit {
            actor_id: removed_by,
            subject_id: user_id,
            action: "remove",
            reason,
            until: None,
            created_at: now,
        },
    )
    .await?;

    Ok(revoked)
}
