// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Account creation: the front-door registration path and the bare fixture
//! primitive. Sessions and tokens live in the parent module.

use super::super::bootstrap::{Bootstrap, claim_in};
use super::super::invites::{record_redemption, spend_invite};
use super::super::{JoinPolicy, Store, now_ms};
use crate::ids::UserId;

/// A freshly created account.
#[derive(Debug, Clone)]
pub struct Account {
    pub id: UserId,
    pub username: String,
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
    /// Raid mode: the Space is not taking new members, invite or not.
    JoinsPaused,
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
        let policy = super::super::space::read_join_policy(&mut *tx).await?;

        if !claimed {
            // The first account claims the deployment in this same commit, so a failure cannot strand it unclaimed.
            if let Bootstrap::AlreadySetUp = claim_in(&mut tx, id).await? {
                return Err(RegisterError::InviteRequired);
            }
            tracing::info!(user_id = %id, "deployment claimed by its first account");
        } else {
            // Dropping `tx` without committing rolls the account insert back, so
            // every early return below leaves the username free.
            let gate = super::super::member_gate::read_join_gate(&mut *tx).await?;
            if gate.joins_paused {
                return Err(RegisterError::JoinsPaused);
            }
            if gate.enabled {
                super::super::member_gate::mark_pending(&mut tx, id, now).await?;
            }
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
}
