// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Refresh-token rotation, and the reuse detection that guards it.
//!
//! Split out of `sessions.rs` when confirm-before-retire pushed that file past
//! its recorded ceiling. It is a real seam rather than a convenient one:
//! everything left there is about establishing or ending a session, while this
//! is the one loop a signed-in client runs forever, and it is the only part
//! with an adversary in its threat model.
//!
//! Rotation confirms before it retires. Spending a refresh token marks it
//! *pending* rather than finished, and it keeps working until the client proves
//! it received the replacement by using the access token issued beside it. That
//! is what stops a rotation whose response was lost - a dropped connection, or
//! the server restarting mid-request - from signing the client out when it
//! retries with the token it still holds.
//!
//! Reuse detection therefore turns on confirmation rather than on a clock. A
//! replayed token that was already retired means its rotation was confirmed and
//! the honest client holds the replacement, so a second copy presenting it is a
//! leak, and the whole family dies.

use sqlx::{Sqlite, SqliteConnection, Transaction};

use super::sessions::{ACCESS_TTL_MS, IssuedTokens, REFRESH_TTL_MS, revoke_session_rows};
use super::{Store, now_ms};
use crate::auth::{generate_secret, hash_secret};
use crate::ids::{DeviceId, FamilyId, SessionId, UserId};

/// The result of presenting a refresh token.
pub enum RefreshOutcome {
    /// Accepted: here are the new access and refresh tokens.
    Rotated(IssuedTokens),
    /// Rejected for a benign reason (unknown, expired, or already revoked).
    Denied,
    /// A spent token was replayed; the family and session were revoked.
    Reused,
}

impl Store {
    /// Retires the refresh token a now-confirmed rotation spent, and clears the
    /// marker so this runs once per rotation rather than on every request.
    ///
    /// Both statements are idempotent and independently safe to lose: if the
    /// process dies between them the worst case is the marker surviving and the
    /// retirement being reapplied, which changes nothing.
    pub(super) async fn retire_confirmed_predecessor(
        &self,
        access_hash: &str,
        predecessor: &str,
        now: i64,
    ) -> anyhow::Result<()> {
        sqlx::query!(
            "UPDATE refresh_tokens SET retired_at = ? WHERE token_hash = ? AND retired_at IS NULL",
            now,
            predecessor
        )
        .execute(&self.pool)
        .await?;
        sqlx::query!(
            "UPDATE access_tokens SET confirms_refresh_hash = NULL WHERE token_hash = ?",
            access_hash
        )
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// Exchanges a refresh token for a new pair, detecting replay of a retired one.
    ///
    /// Rotation confirms before it retires. Spending a token marks it *pending*
    /// rather than finished: it keeps working until the client proves it
    /// received the replacement, which it does by using the access token issued
    /// beside it (see [`Store::authenticate`]). A rotation whose response never
    /// reached the client therefore leaves that client able to try again with
    /// the token it still holds, instead of being signed out for replaying one
    /// the server had already spent.
    ///
    /// The cost is that a rotation the client never confirms leaves both tokens
    /// live until they expire. That is the same exposure as a refresh request
    /// that never reached the server at all, which this system must tolerate
    /// regardless, and it buys back the sign-out.
    ///
    /// `refresh_tokens.successor_hash` (migration 0071) is deliberately never
    /// written. Revoking the previous successor when a pending token rotates
    /// again would strand a client whose two concurrent refreshes raced and
    /// that kept the earlier response; the server cannot tell that apart from
    /// a lost response, and `concurrent_refresh_of_same_token_never_errors`
    /// holds the line on never stranding it.
    ///
    /// The claim is still the transaction's first statement, so it takes the
    /// write lock up front and a concurrent rotation waits on the lock rather
    /// than racing a stale snapshot. `used_at` is set with `COALESCE` so a
    /// replay records the first spend, never pushing the timestamp forward.
    pub async fn rotate_refresh(&self, refresh_token: &str) -> anyhow::Result<RefreshOutcome> {
        self.rotate_refresh_reporting(refresh_token, None, None)
            .await
    }

    /// [`Self::rotate_refresh`], also recording the client kind and version the
    /// app reports, so the devices list follows an app update instead of
    /// keeping the version it signed in with. `None` leaves a field as it was.
    pub async fn rotate_refresh_reporting(
        &self,
        refresh_token: &str,
        client_kind: Option<&str>,
        client_version: Option<&str>,
    ) -> anyhow::Result<RefreshOutcome> {
        let presented = hash_secret(refresh_token);
        let now = now_ms();
        let mut tx = self.begin_write().await?;

        // Claim-first, so this opens on a write; see this function's doc.
        let claimed = sqlx::query!(
            r#"UPDATE refresh_tokens SET used_at = COALESCE(used_at, ?)
               WHERE token_hash = ? AND retired_at IS NULL AND revoked_at IS NULL AND expires_at > ?
               RETURNING session_id AS "session_id!: SessionId",
                         family_id AS "family_id!: FamilyId""#,
            now,
            presented,
            now
        )
        .fetch_optional(&mut *tx)
        .await?;

        let Some(claimed) = claimed else {
            return classify_failed_refresh(tx, &presented, now).await;
        };

        // The claim guard already excludes revoked rows; this is belt and braces.
        let session = sqlx::query!(
            r#"SELECT user_id AS "user_id!: UserId",
                      device_id AS "device_id!: DeviceId",
                      revoked_at
               FROM sessions WHERE id = ?"#,
            claimed.session_id
        )
        .fetch_one(&mut *tx)
        .await?;
        if session.revoked_at.is_some() {
            return Ok(RefreshOutcome::Denied);
        }

        super::safety::touch_device(&mut tx, session.device_id, now).await?;
        if client_kind.is_some() || client_version.is_some() {
            sqlx::query!(
                "UPDATE devices SET client_kind = COALESCE(?, client_kind),
                                    client_version = COALESCE(?, client_version)
                 WHERE id = ?",
                client_kind,
                client_version,
                session.device_id
            )
            .execute(&mut *tx)
            .await?;
        }

        let access_token = generate_secret();
        let refresh_token = generate_secret();
        let access_hash = hash_secret(&access_token);
        let refresh_hash = hash_secret(&refresh_token);
        let access_expires_at = now + ACCESS_TTL_MS;
        let refresh_expires_at = now + REFRESH_TTL_MS;

        sqlx::query!(
            "INSERT INTO refresh_tokens (token_hash, session_id, family_id, issued_at, expires_at)
             VALUES (?, ?, ?, ?, ?)",
            refresh_hash,
            claimed.session_id,
            claimed.family_id,
            now,
            refresh_expires_at
        )
        .execute(&mut *tx)
        .await?;
        sqlx::query!(
            "DELETE FROM access_tokens WHERE session_id = ?",
            claimed.session_id
        )
        .execute(&mut *tx)
        .await?;
        sqlx::query!(
            "INSERT INTO access_tokens (token_hash, session_id, user_id, device_id, issued_at, expires_at, confirms_refresh_hash)
             VALUES (?, ?, ?, ?, ?, ?, ?)",
            access_hash,
            claimed.session_id,
            session.user_id,
            session.device_id,
            now,
            access_expires_at,
            presented
        )
        .execute(&mut *tx)
        .await?;
        tx.commit().await?;

        Ok(RefreshOutcome::Rotated(IssuedTokens {
            access_token,
            refresh_token,
            access_expires_at,
            refresh_expires_at,
            session_id: claimed.session_id,
            user_id: session.user_id,
            device_id: session.device_id,
            known_install: false,
        }))
    }
}

/// Sorts out why a refresh claim matched no row: unknown, revoked, expired, or
/// a genuine reuse. Only the last revokes the family and session.
///
/// A pending token no longer reaches here at all - the claim accepts it - so
/// reaching here with a spent token means it was retired, which means its
/// rotation was confirmed and the client holds the replacement. A second copy
/// presenting it is the leak reuse detection exists to catch.
///
/// Expiry is deliberately not checked on that path: a token that expired
/// recently is exactly the one an attacker would replay, and
/// [`super::sessions::REFRESH_SWEEP_GRACE_MS`] keeps the row precisely so it is still caught.
async fn classify_failed_refresh(
    mut tx: Transaction<'_, Sqlite>,
    presented: &str,
    now: i64,
) -> anyhow::Result<RefreshOutcome> {
    let row = sqlx::query!(
        r#"SELECT session_id AS "session_id!: SessionId",
                  family_id AS "family_id!: FamilyId",
                  retired_at, revoked_at
           FROM refresh_tokens WHERE token_hash = ?"#,
        presented
    )
    .fetch_optional(&mut *tx)
    .await?;

    let Some(row) = row else {
        // Swept or never issued; the one rejection with no session to name.
        tracing::info!(reason = "unknown", "refresh rejected");
        return Ok(RefreshOutcome::Denied);
    };
    if row.revoked_at.is_some() {
        tracing::info!(
            session_id = %row.session_id,
            reason = "family already revoked",
            "refresh rejected"
        );
        return Ok(RefreshOutcome::Denied);
    }
    let Some(retired_at) = row.retired_at else {
        // Live and un-retired, so the claim guard failed on expiry instead.
        tracing::info!(
            session_id = %row.session_id,
            reason = "expired",
            "refresh rejected"
        );
        return Ok(RefreshOutcome::Denied);
    };
    // A retired token was replayed, so this copy is a leak; revoke everything.
    revoke_family(&mut tx, row.family_id, now).await?;
    revoke_session_rows(&mut tx, row.session_id, now).await?;
    tx.commit().await?;
    tracing::warn!(
        session_id = %row.session_id,
        retired_ms_ago = now - retired_at,
        "confirmed refresh token replayed; family and session revoked"
    );
    Ok(RefreshOutcome::Reused)
}

/// Marks every not-yet-revoked token in a family revoked.
async fn revoke_family(
    conn: &mut SqliteConnection,
    family_id: FamilyId,
    now: i64,
) -> anyhow::Result<()> {
    sqlx::query!(
        "UPDATE refresh_tokens SET revoked_at = ? WHERE family_id = ? AND revoked_at IS NULL",
        now,
        family_id
    )
    .execute(conn)
    .await?;
    Ok(())
}
