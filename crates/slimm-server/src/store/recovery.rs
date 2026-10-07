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

use super::moderation_audit::{ModerationAudit, record_moderation_audit};
use super::sessions::revoke_session_rows;
use super::{Store, now_ms};

/// How long an issued code stays redeemable. Short, since it is meant to be
/// handed over and used right away, not stockpiled.
const RESET_CODE_TTL_MS: i64 = 15 * 60 * 1000;

/// Why issuing a reset code failed.
#[derive(Debug)]
pub enum IssueResetError {
    /// No live account matches the given user id.
    NoSuchUser,
    Internal(anyhow::Error),
}

impl From<sqlx::Error> for IssueResetError {
    fn from(err: sqlx::Error) -> Self {
        IssueResetError::Internal(err.into())
    }
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
    /// expiry.
    pub async fn issue_reset_code(
        &self,
        issued_by: UserId,
        user_id: UserId,
    ) -> Result<(String, i64), IssueResetError> {
        let now = now_ms();
        let expires_at = now + RESET_CODE_TTL_MS;
        let code = generate_secret();
        let hash = hash_secret(&code);

        // The existence check rides inside the INSERT (as `Store::open_session`
        // guards its device insert), leaving no gap for the account to vanish.
        let mut tx = self.begin_write().await?;
        let inserted = sqlx::query!(
            "INSERT INTO password_reset_codes (code_hash, user_id, issued_by, issued_at, expires_at)
             SELECT ?, ?, ?, ?, ?
             WHERE EXISTS (SELECT 1 FROM users WHERE id = ? AND deleted_at IS NULL)",
            hash,
            user_id,
            issued_by,
            now,
            expires_at,
            user_id
        )
        .execute(&mut *tx)
        .await?
        .rows_affected();
        if inserted == 0 {
            return Err(IssueResetError::NoSuchUser);
        }
        record_moderation_audit(
            &mut tx,
            ModerationAudit {
                actor_id: issued_by,
                subject_id: user_id,
                action: "reset_code_issue",
                reason: None,
                until: None,
                created_at: now,
            },
        )
        .await?;
        tx.commit().await?;
        Ok((code, expires_at))
    }

    /// Whether a reset code could currently be spent, without spending it.
    ///
    /// One indexed lookup, for a caller that wants to refuse a doomed request
    /// before paying for something expensive. Deliberately advisory: it is not
    /// an authorization decision and races anything, which is why
    /// [`Store::consume_reset_code`] re-checks the same conditions inside its
    /// own transaction and remains the only thing that can spend a code. Same
    /// two-layer shape `register` uses for the invite gate.
    pub async fn reset_code_is_live(&self, code: &str) -> anyhow::Result<bool> {
        let hash = hash_secret(code);
        let now = now_ms();
        let found = sqlx::query_scalar!(
            r#"SELECT 1 AS "one!: i64" FROM password_reset_codes
               WHERE code_hash = ? AND used_at IS NULL AND expires_at > ?"#,
            hash,
            now
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(found.is_some())
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
    /// The transaction opens with [`Store::begin_write`]. The claiming
    /// `UPDATE` is its first statement either way, so no read precedes the
    /// write lock.
    pub async fn consume_reset_code(
        &self,
        code: &str,
        new_password_hash: &str,
    ) -> Result<Vec<SessionId>, ConsumeResetError> {
        let hash = hash_secret(code);
        let now = now_ms();
        let mut tx = self.begin_write().await?;

        let claimed = sqlx::query!(
            r#"UPDATE password_reset_codes SET used_at = ?
               WHERE code_hash = ? AND used_at IS NULL AND expires_at > ?
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
            return Ok(Vec::new());
        }

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
        Ok(live_sessions)
    }
}
