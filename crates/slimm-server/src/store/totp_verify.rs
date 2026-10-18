// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Meeting a second factor: the sign-in challenge, code verification, the
//! replay guard, and the persistent lockout counter (decision 0048).
//!
//! Split from [`super::totp`] because this is the half that runs
//! unauthenticated, on the login path, where every refusal has to answer the
//! same way regardless of which of several reasons applies.

use crate::auth::{generate_secret, hash_secret};
use crate::ids::UserId;
use crate::totp;

use super::sessions::{IssuedTokens, OpenError};
use super::totp::TotpError;
use super::{Store, now_ms};

/// How long a challenge stays redeemable.
///
/// Five minutes: long enough to unlock a phone, find the authenticator app and
/// wait out a code that was about to roll over, short enough that a challenge
/// intercepted from a log or a proxy is worthless by the time anybody reads it.
const CHALLENGE_TTL_MS: i64 = 5 * 60 * 1000;

/// How long past expiry a spent or stale challenge row is kept before the token
/// sweep takes it. An hour of slack for clock skew, as connect tickets get.
pub(super) const CHALLENGE_SWEEP_GRACE_MS: i64 = 60 * 60 * 1000;

/// A password that was accepted for an account whose factor is enabled.
///
/// Not `Debug`: the challenge is a bearer secret for the rest of the sign-in.
pub struct TotpChallenge {
    pub challenge: String,
    pub expires_at: i64,
}

/// How a second factor was met, so the caller can say so without having to ask
/// what was presented.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TotpProof {
    /// A code from the authenticator app.
    Code,
    /// One of the single-use recovery codes, now spent.
    RecoveryCode,
}

/// What a sign-in that met its second factor produced.
pub struct TotpSignIn {
    pub tokens: IssuedTokens,
    pub proof: TotpProof,
    pub device_name: String,
    pub client_kind: Option<String>,
    /// Unused recovery codes left, so the client can warn somebody who has
    /// nearly run out.
    pub recovery_codes_remaining: i64,
}

/// Why completing a challenge failed. Every variant except
/// [`Self::Locked`] answers the client identically; see
/// [`crate::http::totp`] for why the lock is the one exception.
#[derive(Debug)]
pub enum ChallengeError {
    /// Unknown, expired, already spent, or its account's factor has since
    /// gone. One variant for all four, so this cannot be used to mine which
    /// challenges are live.
    Unusable,
    /// The presented code was wrong, replayed, or out of window.
    BadCode,
    Locked {
        until: i64,
    },
    /// The account or membership went away mid-sign-in.
    Open(OpenError),
    Internal(anyhow::Error),
}

impl From<sqlx::Error> for ChallengeError {
    fn from(err: sqlx::Error) -> Self {
        ChallengeError::Internal(err.into())
    }
}

impl From<anyhow::Error> for ChallengeError {
    fn from(err: anyhow::Error) -> Self {
        ChallengeError::Internal(err)
    }
}

impl Store {
    /// Whether this account needs a second factor before a session is minted.
    pub async fn totp_required_at_sign_in(&self, user_id: UserId) -> anyhow::Result<bool> {
        self.totp_is_enabled(user_id).await
    }

    /// Records that a password was accepted and a second factor is still owed,
    /// stashing the device fields from the login request.
    ///
    /// The device fields are stored rather than re-read from the follow-up
    /// request so the second call cannot name a different device than the one
    /// the password was presented for: otherwise a challenge stolen in transit
    /// would let an attacker mint a session that looks, in the devices list,
    /// like the victim's own laptop.
    pub async fn begin_totp_challenge(
        &self,
        user_id: UserId,
        device_name: &str,
        client_kind: Option<&str>,
        client_version: Option<&str>,
    ) -> anyhow::Result<TotpChallenge> {
        let challenge = generate_secret();
        let hash = hash_secret(&challenge);
        let now = now_ms();
        let expires_at = now + CHALLENGE_TTL_MS;
        sqlx::query!(
            "INSERT INTO totp_challenges
                 (challenge_hash, user_id, device_name, client_kind, client_version,
                  issued_at, expires_at)
             VALUES (?, ?, ?, ?, ?, ?, ?)",
            hash,
            user_id,
            device_name,
            client_kind,
            client_version,
            now,
            expires_at
        )
        .execute(&self.pool)
        .await?;
        Ok(TotpChallenge {
            challenge,
            expires_at,
        })
    }

    /// Spends a challenge against a TOTP code or a recovery code, and mints the
    /// session it was standing in for.
    ///
    /// The challenge is claimed first and only on success, which is the
    /// difference that matters: a wrong code leaves the challenge live so
    /// somebody who fat-fingered six digits can simply retype them, while the
    /// attempt itself is still counted against the lockout below. A challenge
    /// spent on every attempt would turn one typo into a fresh password
    /// round-trip, and a lockout that only the in-process rate limiter enforced
    /// would reset on the next deploy.
    ///
    /// Session minting deliberately happens after the commit rather than inside
    /// it: [`Store::open_session_as`] opens its own transaction, and nesting
    /// one write transaction inside another on a single SQLite connection is
    /// the deadlock this codebase avoids everywhere else. The window that
    /// leaves is that a challenge is spent and the session mint then fails, in
    /// which case the member signs in again from the password - the same
    /// outcome an expired challenge gives, and nothing is left half-granted.
    pub async fn complete_totp_challenge(
        &self,
        challenge: &str,
        code: &str,
        install_id: Option<&str>,
    ) -> Result<TotpSignIn, ChallengeError> {
        let hash = hash_secret(challenge);
        let now = now_ms();
        let mut tx = self.begin_write().await?;

        let pending = sqlx::query!(
            r#"SELECT c.user_id AS "user_id!: UserId", c.device_name,
                      c.client_kind, c.client_version,
                      f.secret, f.last_step, f.failed_attempts, f.locked_until
               FROM totp_challenges c
               JOIN user_totp_factors f ON f.user_id = c.user_id
               WHERE c.challenge_hash = ? AND c.used_at IS NULL AND c.expires_at > ?
                 AND f.confirmed_at IS NOT NULL"#,
            hash,
            now
        )
        .fetch_optional(&mut *tx)
        .await?;
        let Some(pending) = pending else {
            return Err(ChallengeError::Unusable);
        };
        if let Some(until) = pending.locked_until.filter(|until| *until > now) {
            return Err(ChallengeError::Locked { until });
        }

        let secret = self
            .data_key
            .open(&pending.user_id.to_string(), &pending.secret)?;
        let proof = match spend_code(
            &mut tx,
            pending.user_id,
            &secret,
            pending.last_step,
            code,
            now,
        )
        .await?
        {
            Some(proof) => proof,
            None => {
                record_failure(&mut tx, pending.user_id, pending.failed_attempts, now).await?;
                tx.commit().await?;
                return Err(ChallengeError::BadCode);
            }
        };

        let claimed = sqlx::query!(
            "UPDATE totp_challenges SET used_at = ?
             WHERE challenge_hash = ? AND used_at IS NULL AND expires_at > ?",
            now,
            hash,
            now
        )
        .execute(&mut *tx)
        .await?
        .rows_affected();
        if claimed == 0 {
            // Spent between the read and here; rolling back takes the code spend with it.
            return Err(ChallengeError::Unusable);
        }
        let remaining = sqlx::query_scalar!(
            r#"SELECT COUNT(*) AS "n!: i64" FROM totp_recovery_codes
               WHERE user_id = ? AND used_at IS NULL"#,
            pending.user_id
        )
        .fetch_one(&mut *tx)
        .await?;
        tx.commit().await?;

        // Outside the transaction; see this function's own note on why.
        let tokens = self
            .open_session_as(
                pending.user_id,
                &pending.device_name,
                pending.client_kind.as_deref(),
                pending.client_version.as_deref(),
                install_id,
            )
            .await
            .map_err(ChallengeError::Open)?;

        Ok(TotpSignIn {
            tokens,
            proof,
            device_name: pending.device_name,
            client_kind: pending.client_kind,
            recovery_codes_remaining: remaining,
        })
    }

    /// Verifies a code for an already-signed-in member, for the routes that
    /// need current proof before they will change the factor: disabling it and
    /// reissuing recovery codes.
    ///
    /// Accepts a recovery code as well as an authenticator code, and spends
    /// whichever it was. Somebody disabling a factor on a phone they no longer
    /// have is the exact case recovery codes exist for.
    pub async fn verify_totp_for_change(
        &self,
        user_id: UserId,
        code: &str,
    ) -> Result<TotpProof, TotpError> {
        let now = now_ms();
        let mut tx = self.begin_write().await?;
        let factor = sqlx::query!(
            "SELECT secret, last_step, failed_attempts, locked_until
             FROM user_totp_factors WHERE user_id = ? AND confirmed_at IS NOT NULL",
            user_id
        )
        .fetch_optional(&mut *tx)
        .await?;
        let Some(factor) = factor else {
            return Err(TotpError::NotConfirmed);
        };
        if let Some(until) = factor.locked_until.filter(|until| *until > now) {
            return Err(TotpError::Locked { until });
        }

        let secret = self.data_key.open(&user_id.to_string(), &factor.secret)?;
        match spend_code(&mut tx, user_id, &secret, factor.last_step, code, now).await? {
            Some(proof) => {
                tx.commit().await?;
                Ok(proof)
            }
            None => {
                record_failure(&mut tx, user_id, factor.failed_attempts, now).await?;
                tx.commit().await?;
                Err(TotpError::BadCode)
            }
        }
    }

    /// Deletes challenge rows far enough past expiry to be useless, alongside
    /// the other token sweeps.
    pub async fn sweep_expired_totp_challenges(&self) -> anyhow::Result<u64> {
        let cutoff = now_ms() - CHALLENGE_SWEEP_GRACE_MS;
        Ok(sqlx::query!(
            "DELETE FROM totp_challenges WHERE rowid IN
             (SELECT rowid FROM totp_challenges WHERE expires_at < ? LIMIT 5000)",
            cutoff
        )
        .execute(&self.pool)
        .await?
        .rows_affected())
    }
}

/// Spends `code` as either an authenticator code or a recovery code, returning
/// which it was, or `None` if it is neither.
///
/// The TOTP branch is tried first and the replay guard is what makes it
/// single-use: a step at or below `last_step` is refused even though the HMAC
/// matches, so a code read off somebody's screen cannot be used behind them
/// inside its own window. On success the stored step advances, which also
/// retires every earlier still-in-window code.
async fn spend_code(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    user_id: UserId,
    secret: &str,
    last_step: Option<i64>,
    code: &str,
    now: i64,
) -> anyhow::Result<Option<TotpProof>> {
    if let Some(step) = totp::matching_step(secret, code, now)?
        && last_step.is_none_or(|last| step > last)
    {
        sqlx::query!(
            "UPDATE user_totp_factors
             SET last_step = ?, failed_attempts = 0, locked_until = NULL
             WHERE user_id = ?",
            step,
            user_id
        )
        .execute(&mut **tx)
        .await?;
        return Ok(Some(TotpProof::Code));
    }

    // Normalised, so a code retyped without its dashes or in lower case matches.
    let hash = hash_secret(&totp::normalize_recovery_code(code));
    let spent = sqlx::query!(
        "UPDATE totp_recovery_codes SET used_at = ?
         WHERE code_hash = ? AND user_id = ? AND used_at IS NULL",
        now,
        hash,
        user_id
    )
    .execute(&mut **tx)
    .await?
    .rows_affected();
    if spent == 0 {
        return Ok(None);
    }
    sqlx::query!(
        "UPDATE user_totp_factors SET failed_attempts = 0, locked_until = NULL
         WHERE user_id = ?",
        user_id
    )
    .execute(&mut **tx)
    .await?;
    Ok(Some(TotpProof::RecoveryCode))
}

/// Counts one failed attempt and locks the factor once the run reaches
/// [`totp::MAX_FAILURES`].
///
/// Persistent rather than in-process, unlike [`crate::ratelimit`], which is the
/// point: the limiter bounds request rate per caller and resets when the process
/// does, and neither property is enough for a six-digit secret. This bounds
/// total guesses against one account no matter who is asking or how many times
/// the server has restarted.
pub(super) async fn record_failure(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    user_id: UserId,
    failed_attempts: i64,
    now: i64,
) -> anyhow::Result<()> {
    let attempts = failed_attempts + 1;
    let locked_until = (attempts >= totp::MAX_FAILURES).then(|| now + totp::LOCKOUT_MS);
    // Zeroed as the lock goes on, so it lifts into a fresh run rather than one attempt before locking again.
    let stored = if locked_until.is_some() { 0 } else { attempts };
    sqlx::query!(
        "UPDATE user_totp_factors SET failed_attempts = ?, locked_until = ? WHERE user_id = ?",
        stored,
        locked_until,
        user_id
    )
    .execute(&mut **tx)
    .await?;
    Ok(())
}
