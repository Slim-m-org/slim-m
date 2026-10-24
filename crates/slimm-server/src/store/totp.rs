// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Enrolling, confirming and removing a TOTP second factor, and the recovery
//! codes that go with it (decision 0048).
//!
//! Enrolment is two steps on purpose. The first writes an *unconfirmed* factor,
//! which nothing enforces; only a verified code confirms it. A single-step
//! enrolment would let a mis-scanned QR code or a clock nobody checked lock a
//! member out of their own account with no way back except an administrator.
//!
//! Verification, the sign-in challenge and the lockout counter live in
//! [`super::totp_verify`], which is the half that runs on the unauthenticated
//! path.

use crate::auth::hash_secret;
use crate::data_key::DataKey;
use crate::ids::{SessionId, UserId};
use crate::totp;

use super::sessions::revoke_session_rows;
use super::{Store, now_ms};

/// How many recovery codes an enrolment hands out.
///
/// Ten: enough that losing a couple to a bad transcription still leaves a
/// usable set, few enough to print on one line each and actually keep.
pub const RECOVERY_CODE_COUNT: usize = 10;

/// What this deployment does about second factors. Stored on `space_settings`
/// as text; see [`super::space`] for the parse.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TotpPolicy {
    /// New enrolments are refused. Deliberately does NOT stop enforcing a
    /// factor somebody already enabled: flipping this must not silently
    /// weaken an account, and the disable path stays open so anyone already
    /// enrolled can leave under their own steam.
    Off,
    /// Anybody may enrol; nobody has to. The default.
    Optional,
    /// Anybody may enrol, and a member holding an elevated permission is
    /// expected to. Reported to the client rather than enforced at sign-in,
    /// because a hard block at sign-in would lock out the one administrator a
    /// deployment has before they could ever enrol; decision 0048 records
    /// where the enforcement point belongs.
    RequiredForElevated,
}

impl TotpPolicy {
    pub fn as_str(self) -> &'static str {
        match self {
            TotpPolicy::Off => "off",
            TotpPolicy::Optional => "optional",
            TotpPolicy::RequiredForElevated => "required_for_elevated",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "off" => Some(TotpPolicy::Off),
            "optional" => Some(TotpPolicy::Optional),
            "required_for_elevated" => Some(TotpPolicy::RequiredForElevated),
            _ => None,
        }
    }
}

/// What a member's factor looks like from the outside. Carries no secret.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TotpStatus {
    /// An enrolment exists but has not been confirmed by a verified code.
    pub pending: bool,
    /// Confirmed, and therefore enforced at sign-in.
    pub enabled: bool,
    pub confirmed_at: Option<i64>,
    pub recovery_codes_remaining: i64,
}

/// A fresh enrolment, handed to the client exactly once.
///
/// Not `Debug`, the same reason [`crate::store::IssuedTokens`] is not: the
/// secret must not reach a log through a formatter nobody thought about.
pub struct TotpEnrolment {
    pub secret: String,
    pub provisioning_uri: String,
}

/// Why confirming or removing a factor failed.
#[derive(Debug)]
pub enum TotpError {
    /// No enrolment to act on.
    NotEnrolled,
    /// An enrolment exists but is not confirmed, so there is no live factor.
    NotConfirmed,
    /// Already confirmed, so a second confirmation would be a silent re-key.
    AlreadyEnabled,
    /// This deployment does not accept new enrolments.
    PolicyForbids,
    /// The presented code was wrong, replayed, or out of window.
    BadCode,
    /// Too many recent failures; see [`crate::totp::LOCKOUT_MS`]. Carries when
    /// the lock lifts, so a person is told to wait rather than told they are
    /// wrong.
    Locked {
        until: i64,
    },
    Internal(anyhow::Error),
}

impl From<sqlx::Error> for TotpError {
    fn from(err: sqlx::Error) -> Self {
        TotpError::Internal(err.into())
    }
}

impl From<anyhow::Error> for TotpError {
    fn from(err: anyhow::Error) -> Self {
        TotpError::Internal(err)
    }
}

impl Store {
    /// Reads a member's factor state, for `/auth/totp` and for the sign-in
    /// path's "does this account need a second factor" question.
    pub async fn totp_status(&self, user_id: UserId) -> anyhow::Result<TotpStatus> {
        let factor = sqlx::query!(
            "SELECT confirmed_at FROM user_totp_factors WHERE user_id = ?",
            user_id
        )
        .fetch_optional(&self.pool)
        .await?;
        let remaining = sqlx::query_scalar!(
            r#"SELECT COUNT(*) AS "n!: i64" FROM totp_recovery_codes
               WHERE user_id = ? AND used_at IS NULL"#,
            user_id
        )
        .fetch_one(&self.pool)
        .await?;
        Ok(match factor {
            Some(row) => TotpStatus {
                pending: row.confirmed_at.is_none(),
                enabled: row.confirmed_at.is_some(),
                confirmed_at: row.confirmed_at,
                recovery_codes_remaining: remaining,
            },
            None => TotpStatus {
                pending: false,
                enabled: false,
                confirmed_at: None,
                recovery_codes_remaining: 0,
            },
        })
    }

    /// Whether a sign-in for this account has to meet a second factor.
    ///
    /// One indexed lookup on the login hot path, and deliberately not
    /// [`Self::totp_status`], which also counts recovery codes that the
    /// decision does not depend on.
    pub(super) async fn totp_is_enabled(&self, user_id: UserId) -> anyhow::Result<bool> {
        let found = sqlx::query_scalar!(
            r#"SELECT 1 AS "one!: i64" FROM user_totp_factors
               WHERE user_id = ? AND confirmed_at IS NOT NULL"#,
            user_id
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(found.is_some())
    }

    /// Whether `required_for_elevated` is on and this person, who can enrol, has not.
    ///
    /// A bot is never owed one: it has no way to enrol, and a missing
    /// permission that disables a bot is a bug.
    pub async fn elevated_factor_missing(&self, user_id: UserId) -> anyhow::Result<bool> {
        if self.totp_policy().await? != TotpPolicy::RequiredForElevated {
            return Ok(false);
        }
        if self.is_bot(user_id).await? {
            return Ok(false);
        }
        Ok(!self.totp_is_enabled(user_id).await?)
    }

    /// Whether any two-factor secret is already sealed, so a missing data key would lock it.
    pub async fn has_sealed_totp_secrets(&self) -> anyhow::Result<bool> {
        let found = sqlx::query_scalar!(
            r#"SELECT EXISTS(SELECT 1 FROM user_totp_factors WHERE secret LIKE 'enc1:%') AS "found!: bool""#
        )
        .fetch_one(&self.pool)
        .await?;
        Ok(found)
    }

    /// Whether any value in the database needs the data key to open: a sealed
    /// two-factor secret or a sealed module secret.
    pub async fn has_sealed_secrets(&self) -> anyhow::Result<bool> {
        Ok(self.has_sealed_totp_secrets().await? || self.has_sealed_module_secrets().await?)
    }

    /// Seals every two-factor secret still stored in the clear, from before the data key
    /// existed, and warns about any the current key cannot open. Safe to run on every start.
    pub async fn seal_totp_secrets(&self) -> anyhow::Result<()> {
        let rows =
            sqlx::query!(r#"SELECT user_id AS "user_id!: UserId", secret FROM user_totp_factors"#)
                .fetch_all(&self.pool)
                .await?;
        let mut unreadable = 0usize;
        for row in rows {
            let context = row.user_id.to_string();
            if DataKey::is_sealed(&row.secret) {
                unreadable += usize::from(self.data_key.open(&context, &row.secret).is_err());
                continue;
            }
            let sealed = self.data_key.seal(&context, &row.secret)?;
            sqlx::query!(
                "UPDATE user_totp_factors SET secret = ? WHERE user_id = ? AND secret = ?",
                sealed,
                row.user_id,
                row.secret
            )
            .execute(&self.pool)
            .await?;
        }
        if unreadable > 0 {
            tracing::error!(
                unreadable,
                "two-factor secrets the data key cannot open; restore the key file that was \
                 backed up with this database, or clear those members' two-factor"
            );
        }
        Ok(())
    }

    /// Starts an enrolment: mints a secret and stores it unconfirmed.
    ///
    /// Replaces an existing *unconfirmed* enrolment, since a member who
    /// abandoned a half-finished setup should get a fresh secret rather than be
    /// stuck with one their authenticator never kept. An already-confirmed
    /// factor is refused instead: re-keying a live factor has to go through
    /// disable, which needs proof.
    pub async fn begin_totp_enrolment(
        &self,
        user_id: UserId,
        issuer: &str,
        account: &str,
    ) -> Result<TotpEnrolment, TotpError> {
        if self.totp_policy().await? == TotpPolicy::Off {
            return Err(TotpError::PolicyForbids);
        }
        let secret = totp::generate_secret();
        let provisioning_uri = totp::provisioning_uri(&secret, issuer, account)?;
        let sealed = self.data_key.seal(&user_id.to_string(), &secret)?;
        let now = now_ms();

        let mut tx = self.begin_write().await?;
        let existing = sqlx::query!(
            "SELECT confirmed_at FROM user_totp_factors WHERE user_id = ?",
            user_id
        )
        .fetch_optional(&mut *tx)
        .await?;
        if existing.is_some_and(|row| row.confirmed_at.is_some()) {
            return Err(TotpError::AlreadyEnabled);
        }
        sqlx::query!(
            "INSERT INTO user_totp_factors (user_id, secret, created_at)
             SELECT ?, ?, ? WHERE EXISTS (SELECT 1 FROM users WHERE id = ? AND deleted_at IS NULL)
             ON CONFLICT(user_id) DO UPDATE
                SET secret = excluded.secret, created_at = excluded.created_at,
                    confirmed_at = NULL, last_step = NULL,
                    failed_attempts = 0, locked_until = NULL",
            user_id,
            sealed,
            now,
            user_id
        )
        .execute(&mut *tx)
        .await?;
        tx.commit().await?;

        Ok(TotpEnrolment {
            secret,
            provisioning_uri,
        })
    }

    /// Confirms a pending enrolment against a code the member read off their
    /// authenticator, and returns the recovery codes for that factor.
    ///
    /// The recovery codes are returned in plaintext once and stored hashed, the
    /// same shape as an invite or a reset code. They are minted here rather
    /// than at [`Self::begin_totp_enrolment`] so a member never ends up holding
    /// codes for a factor that was abandoned before it worked.
    pub async fn confirm_totp_enrolment(
        &self,
        user_id: UserId,
        code: &str,
    ) -> Result<Vec<String>, TotpError> {
        let now = now_ms();
        let mut tx = self.begin_write().await?;

        let factor = sqlx::query!(
            "SELECT secret, confirmed_at, last_step, failed_attempts, locked_until
             FROM user_totp_factors WHERE user_id = ?",
            user_id
        )
        .fetch_optional(&mut *tx)
        .await?;
        let Some(factor) = factor else {
            return Err(TotpError::NotEnrolled);
        };
        if factor.confirmed_at.is_some() {
            return Err(TotpError::AlreadyEnabled);
        }
        if let Some(until) = factor.locked_until.filter(|until| *until > now) {
            return Err(TotpError::Locked { until });
        }

        let secret = self.data_key.open(&user_id.to_string(), &factor.secret)?;
        let step = totp::matching_step(&secret, code, now)?
            .filter(|step| factor.last_step.is_none_or(|last| *step > last));
        let Some(step) = step else {
            super::totp_verify::record_failure(&mut tx, user_id, factor.failed_attempts, now)
                .await?;
            tx.commit().await?;
            return Err(TotpError::BadCode);
        };

        sqlx::query!(
            "UPDATE user_totp_factors
             SET confirmed_at = ?, last_step = ?, failed_attempts = 0, locked_until = NULL
             WHERE user_id = ?",
            now,
            step,
            user_id
        )
        .execute(&mut *tx)
        .await?;
        let codes = replace_recovery_codes(&mut tx, user_id, now).await?;
        tx.commit().await?;
        Ok(codes)
    }

    /// Issues a fresh set of recovery codes, invalidating the previous set.
    ///
    /// Gated on a current code by the caller ([`crate::http::totp`]), not here,
    /// so the one place that decides what counts as proof stays in the route.
    pub async fn regenerate_totp_recovery_codes(
        &self,
        user_id: UserId,
    ) -> Result<Vec<String>, TotpError> {
        let now = now_ms();
        let mut tx = self.begin_write().await?;
        let confirmed = sqlx::query_scalar!(
            r#"SELECT 1 AS "one!: i64" FROM user_totp_factors
               WHERE user_id = ? AND confirmed_at IS NOT NULL"#,
            user_id
        )
        .fetch_optional(&mut *tx)
        .await?;
        if confirmed.is_none() {
            return Err(TotpError::NotConfirmed);
        }
        let codes = replace_recovery_codes(&mut tx, user_id, now).await?;
        tx.commit().await?;
        Ok(codes)
    }

    /// Removes a member's factor and every recovery code with it.
    ///
    /// Leaves sessions alone, which is the deliberate half of decision 0048:
    /// the member proved both factors to get here, so signing their other
    /// devices out would punish them for tidying up. [`Self::clear_totp_factor`]
    /// is the path that does revoke, because it has no such proof.
    pub async fn remove_totp_factor(&self, user_id: UserId) -> Result<(), TotpError> {
        let mut tx = self.begin_write().await?;
        let removed = sqlx::query!("DELETE FROM user_totp_factors WHERE user_id = ?", user_id)
            .execute(&mut *tx)
            .await?
            .rows_affected();
        if removed == 0 {
            return Err(TotpError::NotEnrolled);
        }
        delete_recovery_codes(&mut tx, user_id).await?;
        discard_challenges(&mut tx, user_id).await?;
        tx.commit().await?;
        Ok(())
    }

    /// An administrator clearing a locked-out member's factor: the factor, its
    /// recovery codes, any outstanding challenge, and every live session go.
    ///
    /// Revoking is the point rather than a side effect. This is the one path
    /// that removes a security control from an account nobody has proved they
    /// own, so if the request came from whoever stole the account, the clear
    /// must not also leave them holding a session. Same reasoning
    /// [`Store::consume_reset_code`] gives for the same move, and the audit
    /// entry the caller writes is the other half.
    ///
    /// `actor_id` is `None` for the operator's `clear-totp` command, which acts
    /// on the database directly and has no signed-in administrator to name.
    ///
    /// Returns the revoked sessions so the caller can close their sockets.
    pub async fn clear_totp_factor(
        &self,
        actor_id: Option<UserId>,
        user_id: UserId,
    ) -> Result<Vec<SessionId>, TotpError> {
        let now = now_ms();
        let mut tx = self.begin_write().await?;

        let removed = sqlx::query!("DELETE FROM user_totp_factors WHERE user_id = ?", user_id)
            .execute(&mut *tx)
            .await?
            .rows_affected();
        if removed == 0 {
            return Err(TotpError::NotEnrolled);
        }
        delete_recovery_codes(&mut tx, user_id).await?;
        discard_challenges(&mut tx, user_id).await?;

        let live: Vec<SessionId> = sqlx::query!(
            r#"SELECT id AS "id!: SessionId" FROM sessions
               WHERE user_id = ? AND revoked_at IS NULL"#,
            user_id
        )
        .fetch_all(&mut *tx)
        .await?
        .into_iter()
        .map(|row| row.id)
        .collect();
        for session_id in &live {
            revoke_session_rows(&mut tx, *session_id, now).await?;
        }

        let action = super::moderation_audit::ModerationAction::TotpCleared.as_str();
        sqlx::query!(
            "INSERT INTO moderation_audit_log (actor_id, subject_id, action, created_at)
             VALUES (?, ?, ?, ?)",
            actor_id,
            user_id,
            action,
            now
        )
        .execute(&mut *tx)
        .await?;

        tx.commit().await?;
        Ok(live)
    }
}

/// Mints a fresh recovery set inside an open transaction, dropping whatever was
/// there. Returns the plaintext codes; only their hashes are stored.
async fn replace_recovery_codes(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    user_id: UserId,
    now: i64,
) -> anyhow::Result<Vec<String>> {
    delete_recovery_codes(tx, user_id).await?;
    let mut codes = Vec::with_capacity(RECOVERY_CODE_COUNT);
    for _ in 0..RECOVERY_CODE_COUNT {
        let code = totp::generate_recovery_code();
        let hash = hash_secret(&totp::normalize_recovery_code(&code));
        sqlx::query!(
            "INSERT INTO totp_recovery_codes (code_hash, user_id, created_at)
             VALUES (?, ?, ?)",
            hash,
            user_id,
            now
        )
        .execute(&mut **tx)
        .await?;
        codes.push(code);
    }
    Ok(codes)
}

async fn delete_recovery_codes(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    user_id: UserId,
) -> anyhow::Result<()> {
    sqlx::query!("DELETE FROM totp_recovery_codes WHERE user_id = ?", user_id)
        .execute(&mut **tx)
        .await?;
    Ok(())
}

/// Drops any outstanding sign-in challenge, so a factor that has just been
/// removed or re-keyed cannot be met by a challenge minted against the old one.
async fn discard_challenges(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    user_id: UserId,
) -> anyhow::Result<()> {
    sqlx::query!("DELETE FROM totp_challenges WHERE user_id = ?", user_id)
        .execute(&mut **tx)
        .await?;
    Ok(())
}
