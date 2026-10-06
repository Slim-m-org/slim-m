// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Session and token persistence: registration, login sessions, opaque access
//! and refresh tokens, and single-use WebSocket connect tickets.
//!
//! The token model has three invariants, each covered by tests:
//!
//! - Rotation. A refresh exchanges the presented token for a new refresh (same
//!   family) and a new access token, and marks the old refresh spent. The prior
//!   access token for the session is dropped in the same step. The spend is an
//!   atomic conditional UPDATE issued as the transaction's first statement, so
//!   two rotations of the same token serialize on the write lock cleanly instead
//!   of racing a stale WAL snapshot into a spurious error.
//! - Reuse detection, gated on confirmation rather than on a clock. A spent
//!   refresh token is *pending*, not finished: it keeps working until the client
//!   proves it received the replacement by using the access token issued beside
//!   it. Replaying a token that has been confirmed and retired means it leaked
//!   and both the attacker and the honest client hold copies, so the whole
//!   family and its session are revoked. Replaying one that is merely pending is
//!   the honest client retrying after a dropped response, and rotates again.
//! - Instant revocation. Revoking a session deletes its access tokens and
//!   connect tickets and marks its refresh tokens revoked, so a killed session's
//!   bearer token stops resolving on the next request rather than at expiry.

use sqlx::SqliteConnection;

mod token_sweep;
pub use token_sweep::SweptTokens;

use super::bootstrap::{Bootstrap, claim_in};
use super::invites::{record_redemption, spend_invite};
use super::{JoinPolicy, Store, now_ms};
use crate::auth::{generate_secret, hash_secret};
use crate::ids::{DeviceId, FamilyId, SessionId, UserId};

/// Access tokens are short so a leaked one has a small window and the auth hot
/// path stays a single indexed lookup.
pub(super) const ACCESS_TTL_MS: i64 = 15 * 60 * 1000;
/// Refresh tokens are long-lived but device-bound and single-use per rotation.
pub(super) const REFRESH_TTL_MS: i64 = 30 * 24 * 60 * 60 * 1000;
/// Connect tickets exist only to bridge a REST auth into a WebSocket upgrade.
const WS_TICKET_TTL_MS: i64 = 30 * 1000;

/// A freshly created account.
#[derive(Debug, Clone)]
pub struct Account {
    pub id: UserId,
    pub username: String,
}

/// The secrets minted for a new or rotated session. The token fields are the
/// plaintext handed to the client once; only their hashes are stored. Not
/// `Debug`, so a secret cannot be logged by accident.
pub struct IssuedTokens {
    pub access_token: String,
    pub refresh_token: String,
    pub access_expires_at: i64,
    pub refresh_expires_at: i64,
    pub session_id: SessionId,
    pub user_id: UserId,
    pub device_id: DeviceId,
    /// True when this sign-in replaced a session of an install the account
    /// already had, so it is a re-login and not a new device.
    pub known_install: bool,
}

/// Who a validated credential resolves to. Carries no secret.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionContext {
    pub user_id: UserId,
    pub session_id: SessionId,
    pub device_id: DeviceId,
}

/// Why registration failed.
#[derive(Debug)]
pub enum RegisterError {
    UsernameTaken,
    /// The deployment has been claimed, so joining is by invitation and no code
    /// was presented.
    InviteRequired,
    /// A code was presented but is expired, spent, revoked, or never existed.
    /// One variant for all four, so registration cannot be used to mine codes.
    InviteUnusable,
    Internal(anyhow::Error),
}

impl From<sqlx::Error> for RegisterError {
    fn from(err: sqlx::Error) -> Self {
        RegisterError::Internal(err.into())
    }
}

impl From<anyhow::Error> for RegisterError {
    fn from(err: anyhow::Error) -> Self {
        RegisterError::Internal(err)
    }
}

/// Why opening a session failed.
#[derive(Debug)]
pub enum OpenError {
    /// The account was deleted between the credential check and session creation,
    /// so no session may be issued for it.
    AccountGone,
    /// The account is live and the password was right, but a moderator has
    /// removed this member from the Space.
    ///
    /// Told apart from [`Self::AccountGone`] because the two want different
    /// words in front of a person: one is "this account no longer exists" and
    /// the other is "you were removed", and offering the first for the second
    /// sends somebody to create a duplicate account to fix it.
    Removed,
    Internal(anyhow::Error),
}

impl From<sqlx::Error> for OpenError {
    fn from(err: sqlx::Error) -> Self {
        OpenError::Internal(err.into())
    }
}

impl Store {
    /// Registers an account through the front door: the deployment's join
    /// policy is applied here, atomically with the account insert.
    ///
    /// An unclaimed deployment accepts anyone, because the first account is
    /// what claims it and there is nobody to issue an invite yet; that account
    /// claims it in this same transaction. Once claimed,
    /// joining is by invitation (see [`crate::store::invites`]), and the invite
    /// is spent in the same transaction that creates the account: a code that
    /// loses the race for its last remaining use leaves no orphan account
    /// behind, and an account that fails to insert never spends a code.
    ///
    /// The account insert is deliberately the transaction's first statement, so
    /// it takes the write lock up front rather than reading a snapshot it would
    /// later have to promote; the same reason [`Self::rotate_refresh`] claims
    /// write-first.
    pub async fn register_account(
        &self,
        username: &str,
        display_name: &str,
        password_hash: &str,
        invite_code: Option<&str>,
    ) -> Result<Account, RegisterError> {
        let id = UserId::generate();
        let now = now_ms();
        let mut tx = self.begin_write().await?;

        let inserted = sqlx::query!(
            "INSERT INTO users (id, username, display_name, password_hash, created_at)
             VALUES (?, ?, ?, ?, ?)",
            id,
            username,
            display_name,
            password_hash,
            now
        )
        .execute(&mut *tx)
        .await;
        match inserted {
            Ok(_) => {}
            Err(sqlx::Error::Database(e)) if e.is_unique_violation() => {
                return Err(RegisterError::UsernameTaken);
            }
            Err(e) => return Err(RegisterError::Internal(e.into())),
        }

        // Read inside the transaction: a deployment claimed by a concurrent
        // first registration must not let this one in ungated.
        let claimed =
            sqlx::query_scalar!(r#"SELECT 1 AS "one!: i64" FROM roles WHERE is_everyone = 1"#)
                .fetch_optional(&mut *tx)
                .await?
                .is_some();

        // Read in the same transaction, for the same reason `claimed` is: a
        // policy change landing concurrently must not be missed here.
        let policy = super::space::read_join_policy(&mut *tx).await?;

        if !claimed {
            // The first account claims the deployment in this same commit, so a
            // failure here cannot strand it as a plain member of an unclaimed one.
            if let Bootstrap::AlreadySetUp = claim_in(&mut tx, id).await? {
                return Err(RegisterError::InviteRequired);
            }
            tracing::info!(user_id = %id, "deployment claimed by its first account");
        } else {
            // Dropping `tx` without committing rolls the account insert back, so
            // every early return below leaves the username free.
            let code = match (invite_code, policy) {
                (Some(code), _) => Some(code),
                // An open Space still accepts a code, so an invite that grants
                // a role keeps working; it just no longer demands one.
                (None, JoinPolicy::Open) => None,
                (None, JoinPolicy::Invite) => return Err(RegisterError::InviteRequired),
            };
            if let Some(code) = code {
                let Some(spent) = spend_invite(&mut tx, code, now).await? else {
                    return Err(RegisterError::InviteUnusable);
                };
                // Record it so this account cannot redeem the same code again for a second use; see SRV5.
                record_redemption(&mut tx, code, id, now).await?;
                if let Some(role_id) = spent {
                    sqlx::query!(
                        "INSERT OR IGNORE INTO member_roles (user_id, role_id) VALUES (?, ?)",
                        id,
                        role_id
                    )
                    .execute(&mut *tx)
                    .await?;
                }
            }
        }

        tx.commit().await?;
        Ok(Account {
            id,
            username: username.to_owned(),
        })
    }

    /// Inserts an account with no join policy applied at all.
    ///
    /// This is the bare primitive, for building a fixture or a scenario. It is
    /// NOT the registration path: a route that calls this reopens the hole
    /// where anyone could join a claimed deployment without an invite. Route
    /// handlers use [`Self::register_account`].
    pub async fn create_account(
        &self,
        username: &str,
        display_name: &str,
        password_hash: &str,
    ) -> Result<Account, RegisterError> {
        let id = UserId::generate();
        let now = now_ms();
        let result = sqlx::query!(
            "INSERT INTO users (id, username, display_name, password_hash, created_at)
             VALUES (?, ?, ?, ?, ?)",
            id,
            username,
            display_name,
            password_hash,
            now
        )
        .execute(&self.pool)
        .await;

        match result {
            Ok(_) => Ok(Account {
                id,
                username: username.to_owned(),
            }),
            Err(sqlx::Error::Database(e)) if e.is_unique_violation() => {
                Err(RegisterError::UsernameTaken)
            }
            Err(e) => Err(RegisterError::Internal(e.into())),
        }
    }

    /// [`Self::open_session_as`] with no client to report.
    pub async fn open_session(
        &self,
        user_id: UserId,
        device_name: &str,
    ) -> Result<IssuedTokens, OpenError> {
        self.open_session_as(user_id, device_name, None, None, None)
            .await
    }

    /// Opens a session for a user: a new device, a session, a refresh token in a
    /// fresh family, and the first access token, all in one transaction.
    ///
    /// The device insert is the transaction's first statement and is conditional
    /// on the account still being live, so it takes the write lock up front and a
    /// login that races an account deletion cannot mint a session for a
    /// tombstoned account: whichever of the two commits first wins, and a loser
    /// login gets [`OpenError::AccountGone`].
    ///
    /// With an `install_id` the device row is the install's own (see
    /// [`install_device_id`]): signing in again reuses it and revokes the
    /// sessions it already held, so one install is one row however often it
    /// signs in. Without one, every sign-in is a fresh device as it always was.
    pub async fn open_session_as(
        &self,
        user_id: UserId,
        device_name: &str,
        client_kind: Option<&str>,
        client_version: Option<&str>,
        install_id: Option<&str>,
    ) -> Result<IssuedTokens, OpenError> {
        let device_id =
            install_id.map_or_else(DeviceId::generate, |i| install_device_id(user_id, i));
        let session_id = SessionId::generate();
        let family_id = FamilyId::generate();

        let access_token = generate_secret();
        let refresh_token = generate_secret();
        let access_hash = hash_secret(&access_token);
        let refresh_hash = hash_secret(&refresh_token);

        let now = now_ms();
        let access_expires_at = now + ACCESS_TTL_MS;
        let refresh_expires_at = now + REFRESH_TTL_MS;

        let mut tx = self.begin_write().await?;
        let known_install = install_id.is_some()
            && sqlx::query_scalar!(
                r#"SELECT 1 AS "one!: i64" FROM devices WHERE id = ? AND user_id = ?"#,
                device_id,
                user_id
            )
            .fetch_optional(&mut *tx)
            .await?
            .is_some();
        let created = sqlx::query!(
            "INSERT INTO devices (id, user_id, name, created_at, last_seen_at, client_kind, client_version)
             SELECT ?, ?, ?, ?, ?, ?, ? WHERE EXISTS (SELECT 1 FROM users WHERE id = ? AND deleted_at IS NULL)
               AND NOT EXISTS (SELECT 1 FROM space_removals WHERE user_id = ?)
             ON CONFLICT(id) DO UPDATE SET name = excluded.name, last_seen_at = excluded.last_seen_at,
               client_kind = excluded.client_kind, client_version = excluded.client_version",
            device_id, user_id, device_name, now, now, client_kind, client_version, user_id, user_id
        )
        .execute(&mut *tx)
        .await?
        .rows_affected();
        if created == 0 {
            // Decided in the same transaction, so it cannot disagree with the insert.
            return Err(if super::removals::removed(&mut tx, user_id).await? {
                OpenError::Removed
            } else {
                OpenError::AccountGone
            });
        }
        if known_install {
            let previous = sqlx::query_scalar!(
                r#"SELECT id AS "id!: SessionId" FROM sessions
                   WHERE device_id = ? AND revoked_at IS NULL"#,
                device_id
            )
            .fetch_all(&mut *tx)
            .await?;
            for old in previous {
                revoke_session_rows(&mut tx, old, now)
                    .await
                    .map_err(OpenError::Internal)?;
            }
        }
        sqlx::query!(
            "INSERT INTO sessions (id, user_id, device_id, created_at) VALUES (?, ?, ?, ?)",
            session_id,
            user_id,
            device_id,
            now
        )
        .execute(&mut *tx)
        .await?;
        sqlx::query!(
            "INSERT INTO refresh_tokens (token_hash, session_id, family_id, issued_at, expires_at)
             VALUES (?, ?, ?, ?, ?)",
            refresh_hash,
            session_id,
            family_id,
            now,
            refresh_expires_at
        )
        .execute(&mut *tx)
        .await?;
        sqlx::query!(
            "INSERT INTO access_tokens (token_hash, session_id, user_id, device_id, issued_at, expires_at)
             VALUES (?, ?, ?, ?, ?, ?)",
            access_hash,
            session_id,
            user_id,
            device_id,
            now,
            access_expires_at
        )
        .execute(&mut *tx)
        .await?;
        tx.commit().await?;

        Ok(IssuedTokens {
            access_token,
            refresh_token,
            access_expires_at,
            refresh_expires_at,
            session_id,
            user_id,
            device_id,
            known_install,
        })
    }

    /// Resolves a presented access token to its session, or `None` if unknown or
    /// expired. Revoked sessions have their access tokens deleted, so absence is
    /// sufficient here and this stays one indexed lookup with no join.
    ///
    /// Using an access token is also how a client confirms the rotation that
    /// issued it, which retires the refresh token that rotation spent. The
    /// confirmation is one extra write, and only on the first request after a
    /// rotation: `confirms_refresh_hash` is cleared as it is acted on, and is
    /// already NULL for every later request and for every sign-in token. So the
    /// hot path keeps costing exactly the lookup above.
    pub async fn authenticate(&self, access_token: &str) -> anyhow::Result<Option<SessionContext>> {
        let hash = hash_secret(access_token);
        let now = now_ms();
        let row = sqlx::query!(
            r#"SELECT user_id AS "user_id!: UserId",
                      session_id AS "session_id!: SessionId",
                      device_id AS "device_id!: DeviceId",
                      confirms_refresh_hash
               FROM access_tokens
               WHERE token_hash = ? AND expires_at > ?"#,
            hash,
            now
        )
        .fetch_optional(&self.pool)
        .await?;
        let Some(row) = row else {
            return Ok(None);
        };
        if let Some(predecessor) = row.confirms_refresh_hash.as_deref() {
            self.retire_confirmed_predecessor(&hash, predecessor, now)
                .await?;
        }
        Ok(Some(SessionContext {
            user_id: row.user_id,
            session_id: row.session_id,
            device_id: row.device_id,
        }))
    }

    /// Mints a single-use connect ticket from an already-authenticated session,
    /// returning the ticket secret and its expiry.
    pub async fn mint_ws_ticket(&self, ctx: &SessionContext) -> anyhow::Result<(String, i64)> {
        let ticket = generate_secret();
        let hash = hash_secret(&ticket);
        let now = now_ms();
        let expires_at = now + WS_TICKET_TTL_MS;
        sqlx::query!(
            "INSERT INTO ws_tickets (ticket_hash, session_id, user_id, device_id, issued_at, expires_at)
             VALUES (?, ?, ?, ?, ?, ?)",
            hash,
            ctx.session_id,
            ctx.user_id,
            ctx.device_id,
            now,
            expires_at
        )
        .execute(&self.pool)
        .await?;
        Ok((ticket, expires_at))
    }

    /// Redeems a connect ticket exactly once. Returns the session it authorizes,
    /// or `None` if the ticket is unknown, expired, already used, or its session
    /// has been revoked.
    pub async fn redeem_ws_ticket(&self, ticket: &str) -> anyhow::Result<Option<SessionContext>> {
        let hash = hash_secret(ticket);
        let now = now_ms();
        let mut tx = self.begin_write().await?;

        // Claimed atomically as the first statement, so a double redemption
        // cannot have both callers pass the `used_at` check.
        let claimed = sqlx::query!(
            r#"UPDATE ws_tickets SET used_at = ?
               WHERE ticket_hash = ? AND used_at IS NULL AND expires_at > ?
               RETURNING user_id AS "user_id!: UserId",
                         session_id AS "session_id!: SessionId",
                         device_id AS "device_id!: DeviceId""#,
            now,
            hash,
            now
        )
        .fetch_optional(&mut *tx)
        .await?;

        let Some(claimed) = claimed else {
            return Ok(None);
        };
        super::safety::touch_device(&mut tx, claimed.device_id, now).await?;

        // Revocation deletes a session's tickets, so a live one here is rejected anyway.
        let session = sqlx::query!(
            r#"SELECT revoked_at FROM sessions WHERE id = ?"#,
            claimed.session_id
        )
        .fetch_optional(&mut *tx)
        .await?;
        if session.map(|s| s.revoked_at.is_some()).unwrap_or(true) {
            tx.commit().await?;
            return Ok(None);
        }
        tx.commit().await?;

        Ok(Some(SessionContext {
            user_id: claimed.user_id,
            session_id: claimed.session_id,
            device_id: claimed.device_id,
        }))
    }

    /// Revokes one session immediately (logout). Its bearer tokens stop
    /// resolving on the next request.
    pub async fn revoke_session(&self, session_id: SessionId) -> anyhow::Result<()> {
        let now = now_ms();
        let mut tx = self.begin_write().await?;
        revoke_session_rows(&mut tx, session_id, now).await?;
        tx.commit().await?;
        Ok(())
    }
}

/// The device row an install owns on one account.
///
/// Derived, not stored, so no schema change is needed: a hash of the account
/// and the client's `install_id`, shaped as a UUID. Scoping by account means
/// the same install id on two accounts is two devices, and nobody can claim a
/// device row that belongs to someone else by guessing its id.
pub(crate) fn install_device_id(user_id: UserId, install_id: &str) -> DeviceId {
    use sha2::{Digest, Sha256};
    let digest = Sha256::new()
        .chain_update(b"slimm-install-device-v1")
        .chain_update(user_id.0.as_bytes())
        .chain_update(install_id.as_bytes())
        .finalize();
    let mut bytes = [0u8; 16];
    bytes.copy_from_slice(&digest[..16]);
    DeviceId(uuid::Builder::from_custom_bytes(bytes).into_uuid())
}

/// Tears down a session's live credentials: access tokens and connect tickets
/// gone, refresh tokens marked revoked, the session itself marked revoked, and
/// its device's push registration cleared.
///
/// The registration is cleared here, not left to the read-side liveness
/// filter in [`Store::push_targets`] alone, so a signed-out device stops being
/// a push target the instant it is revoked rather than on whatever cadence
/// the next read happens to run.
///
/// Both timestamp writes are guarded on the row still being live, so calling
/// this for an already-revoked session is a no-op on when it died rather than
/// a re-stamp. That matters wherever a caller revokes a set it did not filter
/// first, as [`Store::remove_device`] does.
pub(super) async fn revoke_session_rows(
    conn: &mut SqliteConnection,
    session_id: SessionId,
    now: i64,
) -> anyhow::Result<()> {
    sqlx::query!(
        "UPDATE devices
         SET platform = NULL, push_token_ref = NULL, voip_push_token_ref = NULL,
             push_public_key = NULL
         WHERE id = (SELECT device_id FROM sessions WHERE id = ?)",
        session_id
    )
    .execute(&mut *conn)
    .await?;
    sqlx::query!("DELETE FROM access_tokens WHERE session_id = ?", session_id)
        .execute(&mut *conn)
        .await?;
    sqlx::query!("DELETE FROM ws_tickets WHERE session_id = ?", session_id)
        .execute(&mut *conn)
        .await?;
    sqlx::query!(
        "UPDATE refresh_tokens SET revoked_at = ? WHERE session_id = ? AND revoked_at IS NULL",
        now,
        session_id
    )
    .execute(&mut *conn)
    .await?;
    // Guarded like the refresh_tokens update above; see this function's doc.
    sqlx::query!(
        "UPDATE sessions SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL",
        now,
        session_id
    )
    .execute(&mut *conn)
    .await?;
    Ok(())
}
