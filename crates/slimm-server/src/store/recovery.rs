// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Admin-issued password reset codes: the self-hosted recovery path chosen in
//! place of email, since a self-hosted deployment has no mail server to trust
//! and the owner decided against wiring one in for this.
//!
//! An administrator issues a one-time code for a specific account; whoever
//! holds it spends it once to set a new password. The code is stored only as
//! a hash, exactly as every other bearer secret in this codebase is (see
//! [`crate::auth::hash_secret`]), so a database leak alone cannot be used to
//! reset anyone's password. Consuming it revokes every live session on the
//! account: the whole point of this path is recovering an account that may be
//! compromised, not just changing its password out from under a session an
//! attacker still holds.

use crate::auth::{generate_secret, hash_secret};
use crate::ids::{SessionId, UserId};

use super::moderation_audit::{ModerationAction, ModerationAudit, record_moderation_audit};
use super::sessions::revoke_session_rows;
use super::totp::discard_challenges;
use super::{Store, now_ms};

/// How long an issued code stays redeemable. Short, since it is meant to be
/// handed over and used right away, not stockpiled.
const RESET_CODE_TTL_MS: i64 = 15 * 60 * 1000;

/// Why issuing a reset code failed.
#[derive(Debug)]
pub enum IssueResetError {
    /// No live account matches the given user id.
    NoSuchUser,
    /// A bot or webhook, whose credential is its token, never a password.
    NotAPerson,
    Internal(anyhow::Error),
}

impl From<sqlx::Error> for IssueResetError {
    fn from(err: sqlx::Error) -> Self {
        IssueResetError::Internal(err.into())
    }
}

/// A spent reset code: whose account it was, and the sessions it revoked.
#[derive(Debug)]
pub struct ResetConsumed {
    pub user_id: UserId,
    pub revoked: Vec<SessionId>,
}

/// Why consuming a reset code failed. Deliberately one variant: an unknown,
/// expired, and already-used code all answer the same way, so the endpoint
/// cannot be used to mine which codes are still live.
#[derive(Debug)]
pub enum ConsumeResetError {
    Unusable,
    Internal(anyhow::Error),
}

impl From<sqlx::Error> for ConsumeResetError {
    fn from(err: sqlx::Error) -> Self {
        ConsumeResetError::Internal(err.into())
    }
}

impl From<anyhow::Error> for ConsumeResetError {
    fn from(err: anyhow::Error) -> Self {
        ConsumeResetError::Internal(err)
    }
}

impl Store {
    /// Issues a one-time reset code for `user_id`. Returns the plaintext code
    /// (handed to the administrator once; only its hash is stored) and its
    /// expiry. A bot or webhook is refused: its token is its only credential.
    pub async fn issue_reset_code(
        &self,
        issued_by: UserId,
        user_id: UserId,
    ) -> Result<(String, i64), IssueResetError> {
        let now = now_ms();
        let expires_at = now + RESET_CODE_TTL_MS;
        let code = generate_secret();
        let hash = hash_secret(&code);

        let mut tx = self.begin_write().await?;
        let target = sqlx::query!(
            r#"SELECT is_bot AS "is_bot!: bool", is_webhook AS "is_webhook!: bool"
               FROM users WHERE id = ? AND deleted_at IS NULL"#,
            user_id
        )
        .fetch_optional(&mut *tx)
        .await?
        .ok_or(IssueResetError::NoSuchUser)?;
        if target.is_bot || target.is_webhook {
            return Err(IssueResetError::NotAPerson);
        }
        sqlx::query!(
            "INSERT INTO password_reset_codes (code_hash, user_id, issued_by, issued_at, expires_at)
             VALUES (?, ?, ?, ?, ?)",
            hash,
            user_id,
            issued_by,
            now,
            expires_at
        )
        .execute(&mut *tx)
        .await?;
        record_moderation_audit(
            &mut tx,
            ModerationAudit {
                actor_id: issued_by,
                subject_id: user_id,
                action: ModerationAction::ResetCodeIssue,
                reason: None,
                until: None,
                created_at: now,
            },
        )
        .await?;
        tx.commit().await?;
        Ok((code, expires_at))
    }

    /// Who issued a reset code that could currently be spent, without spending it.
    ///
    /// `None` for an unknown, spent or expired code, and for one whose issuer
    /// has since been deleted or removed. Advisory, like `register`'s invite
    /// check: [`Store::consume_reset_code`] re-checks the same conditions in
    /// its own transaction and alone spends a code. Whether the issuer still
    /// holds ADMINISTRATOR is the caller's check, through the permission evaluator.
    pub async fn reset_code_issuer(&self, code: &str) -> anyhow::Result<Option<UserId>> {
        let hash = hash_secret(code);
        let now = now_ms();
        let issuer = sqlx::query_scalar!(
            r#"SELECT c.issued_by AS "issued_by!: UserId" FROM password_reset_codes c
               JOIN users i ON i.id = c.issued_by AND i.deleted_at IS NULL
               WHERE c.code_hash = ? AND c.used_at IS NULL AND c.expires_at > ?
                 AND NOT EXISTS (SELECT 1 FROM space_removals r WHERE r.user_id = c.issued_by)"#,
            hash,
            now
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(issuer)
    }

    /// Spends a reset code exactly once, setting a new password hash and
    /// revoking every live session on the account. Returns the sessions that
    /// were revoked, so the caller can close their live sockets the same way
    /// [`Store::delete_account`] and [`Store::remove_device`] do.
    ///
    /// The claim, the password write, and every session revocation share one
    /// transaction, committed once at the end. That matters here more than in
    /// most places: this path exists to recover an account an attacker may
    /// still hold a session on, and the code that authorizes it can only ever
    /// be spent once. A commit that lands after the claim and the password
    /// write but before the revocations would leave that exact attacker
    /// session alive with no way to retry, since the one thing that could
    /// authorize a second attempt is now spent. Doing it all in one
    /// transaction means a failure anywhere in the middle rolls the whole
    /// thing back: the code stays live and the caller can simply try again.
    ///
    /// A code is only as good as its issuer's standing, so one whose issuer
    /// was since deleted or removed is refused like a spent one. Spending a
    /// code also spends every sibling and drops pending two-factor challenges.
    ///
    /// The transaction opens with [`Store::begin_write`]. The claiming
    /// `UPDATE` is its first statement either way, so no read precedes the
    /// write lock.
    pub async fn consume_reset_code(
        &self,
        code: &str,
        new_password_hash: &str,
    ) -> Result<ResetConsumed, ConsumeResetError> {
        let hash = hash_secret(code);
        let now = now_ms();
        let mut tx = self.begin_write().await?;

        let claimed = sqlx::query!(
            r#"UPDATE password_reset_codes SET used_at = ?
               WHERE code_hash = ? AND used_at IS NULL AND expires_at > ?
                 AND issued_by IN (SELECT id FROM users WHERE deleted_at IS NULL)
                 AND NOT EXISTS (SELECT 1 FROM space_removals r WHERE r.user_id = issued_by)
                 AND user_id IN (SELECT id FROM users WHERE is_bot = 0 AND is_webhook = 0)
               RETURNING user_id AS "user_id!: UserId""#,
            now,
            hash,
            now
        )
        .fetch_optional(&mut *tx)
        .await?;
        let Some(claimed) = claimed else {
            return Err(ConsumeResetError::Unusable);
        };

        let updated = sqlx::query!(
            "UPDATE users SET password_hash = ? WHERE id = ? AND deleted_at IS NULL",
            new_password_hash,
            claimed.user_id
        )
        .execute(&mut *tx)
        .await?
        .rows_affected();
        if updated == 0 {
            // The account went away between issue and consume. The code is
            // spent regardless and there is nothing left to secure.
            tx.commit().await?;
            return Ok(ResetConsumed {
                user_id: claimed.user_id,
                revoked: Vec::new(),
            });
        }

        retire_password_proofs(&mut tx, claimed.user_id, now).await?;

        let live_sessions: Vec<SessionId> = sqlx::query!(
            r#"SELECT id AS "id!: SessionId" FROM sessions
               WHERE user_id = ? AND revoked_at IS NULL"#,
            claimed.user_id
        )
        .fetch_all(&mut *tx)
        .await?
        .into_iter()
        .map(|r| r.id)
        .collect();
        for session_id in &live_sessions {
            revoke_session_rows(&mut tx, *session_id, now).await?;
        }
        tx.commit().await?;
        Ok(ResetConsumed {
            user_id: claimed.user_id,
            revoked: live_sessions,
        })
    }

    /// Sets a new password hash and revokes every live session except
    /// `keep`, the one that made the change, in one transaction. Pending
    /// two-factor challenges and unspent reset codes go with the old password.
    ///
    /// Returns the revoked sessions so the caller can close their sockets.
    pub async fn change_password(
        &self,
        user_id: UserId,
        keep: SessionId,
        new_password_hash: &str,
    ) -> anyhow::Result<Vec<SessionId>> {
        let now = now_ms();
        let mut tx = self.begin_write().await?;
        sqlx::query!(
            "UPDATE users SET password_hash = ? WHERE id = ? AND deleted_at IS NULL",
            new_password_hash,
            user_id
        )
        .execute(&mut *tx)
        .await?;
        retire_password_proofs(&mut tx, user_id, now).await?;
        let others: Vec<SessionId> = sqlx::query!(
            r#"SELECT id AS "id!: SessionId" FROM sessions
               WHERE user_id = ? AND revoked_at IS NULL AND id != ?"#,
            user_id,
            keep
        )
        .fetch_all(&mut *tx)
        .await?
        .into_iter()
        .map(|r| r.id)
        .collect();
        for session_id in &others {
            revoke_session_rows(&mut tx, *session_id, now).await?;
        }
        tx.commit().await?;
        Ok(others)
    }
}

/// Retires what was proven against the password being replaced: pending
/// two-factor sign-ins and every reset code still unspent.
async fn retire_password_proofs(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    user_id: UserId,
    now: i64,
) -> anyhow::Result<()> {
    discard_challenges(tx, user_id).await?;
    sqlx::query!(
        "UPDATE password_reset_codes SET used_at = ? WHERE user_id = ? AND used_at IS NULL",
        now,
        user_id
    )
    .execute(&mut **tx)
    .await?;
    Ok(())
}
