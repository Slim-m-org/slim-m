// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Accounts members link from elsewhere (Discord), the one-time states that
//! tie an OAuth callback back to the member who started it, and the handoffs
//! that let that member's own app finish the link.

use rand_core::{OsRng, RngCore};

use super::{Store, now_ms};
use crate::auth::hash_secret;
use crate::ids::UserId;

/// Letters and digits people do not misread; a power of two long, so a masked byte picks one without bias.
const HANDOFF_ALPHABET: &[u8; 32] = b"ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
const HANDOFF_LEN: usize = 25;

/// A handoff code as stored and compared: pasted text may carry dashes, spaces or lower case.
pub fn normalize_handoff(raw: &str) -> String {
    raw.chars()
        .filter(char::is_ascii_alphanumeric)
        .map(|c| c.to_ascii_uppercase())
        .collect()
}

/// A fresh 125-bit handoff code.
fn generate_handoff() -> String {
    let mut bytes = [0u8; HANDOFF_LEN];
    OsRng.fill_bytes(&mut bytes);
    bytes
        .iter()
        .map(|b| char::from(HANDOFF_ALPHABET[usize::from(b & 31)]))
        .collect()
}

/// A linked account as shown on a profile.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LinkedAccount {
    pub provider: String,
    pub external_id: String,
    pub username: String,
    pub display_name: Option<String>,
    pub linked_at: i64,
    /// When the server stored the account's picture; `None` when it has none.
    pub avatar_updated_at: Option<i64>,
}

/// An account the provider vouched for, held until the member who started the
/// link finishes it from their own app.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PendingLink {
    /// The member who started the link, and the only one who may finish it.
    pub user_id: UserId,
    pub external_id: String,
    pub username: String,
    pub display_name: Option<String>,
    /// The provider's picture hash; the picture itself is fetched on completion.
    pub avatar_hash: Option<String>,
}

/// Why a link was not saved.
#[derive(Debug)]
pub enum AccountLinkError {
    /// That external account is already linked to another member.
    TakenByAnotherMember,
    Internal(anyhow::Error),
}

impl From<sqlx::Error> for AccountLinkError {
    fn from(err: sqlx::Error) -> Self {
        AccountLinkError::Internal(err.into())
    }
}

impl Store {
    /// Remembers `state` for `user_id` until `expires_at`, dropping any
    /// states that have already expired.
    pub async fn create_link_state(
        &self,
        user_id: UserId,
        provider: &str,
        state: &str,
        expires_at: i64,
    ) -> anyhow::Result<()> {
        let now = now_ms();
        let mut tx = self.begin_write().await?;
        sqlx::query!("DELETE FROM link_states WHERE expires_at <= ?", now)
            .execute(&mut *tx)
            .await?;
        sqlx::query!(
            "INSERT INTO link_states (state, user_id, provider, expires_at) VALUES (?, ?, ?, ?)",
            state,
            user_id,
            provider,
            expires_at
        )
        .execute(&mut *tx)
        .await?;
        tx.commit().await?;
        Ok(())
    }

    /// Spends `state`: the member who started this link, once, while it is
    /// still valid. A replayed or expired state answers `None`.
    pub async fn take_link_state(
        &self,
        state: &str,
        provider: &str,
    ) -> anyhow::Result<Option<UserId>> {
        let row = sqlx::query!(
            r#"DELETE FROM link_states WHERE state = ? AND provider = ?
               RETURNING user_id AS "user_id!: UserId", expires_at AS "expires_at!""#,
            state,
            provider
        )
        .fetch_optional(&self.pool)
        .await?;
        let now = now_ms();
        Ok(row
            .filter(|row| row.expires_at > now)
            .map(|row| row.user_id))
    }

    /// Holds `pending` under a fresh handoff code until `expires_at`, dropping
    /// any handoffs that have already expired. Only the code's hash is kept.
    pub async fn create_link_handoff(
        &self,
        provider: &str,
        pending: &PendingLink,
        expires_at: i64,
    ) -> anyhow::Result<String> {
        let code = generate_handoff();
        let hash = hash_secret(&code);
        let now = now_ms();
        let mut tx = self.begin_write().await?;
        sqlx::query!("DELETE FROM link_handoffs WHERE expires_at <= ?", now)
            .execute(&mut *tx)
            .await?;
        sqlx::query!(
            "INSERT INTO link_handoffs
                 (handoff_hash, user_id, provider, external_id, username, display_name,
                  avatar_hash, expires_at)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            hash,
            pending.user_id,
            provider,
            pending.external_id,
            pending.username,
            pending.display_name,
            pending.avatar_hash,
            expires_at
        )
        .execute(&mut *tx)
        .await?;
        tx.commit().await?;
        Ok(code)
    }

    /// Spends a handoff, whoever presents it: the pending link, once, while it
    /// is still valid. An unknown, replayed or expired code answers `None`.
    pub async fn take_link_handoff(
        &self,
        code: &str,
        provider: &str,
    ) -> anyhow::Result<Option<PendingLink>> {
        let hash = hash_secret(&normalize_handoff(code));
        let row = sqlx::query!(
            r#"DELETE FROM link_handoffs WHERE handoff_hash = ? AND provider = ?
               RETURNING user_id AS "user_id!: UserId", external_id AS "external_id!",
                         username AS "username!", display_name, avatar_hash,
                         expires_at AS "expires_at!""#,
            hash,
            provider
        )
        .fetch_optional(&self.pool)
        .await?;
        let now = now_ms();
        Ok(row
            .filter(|row| row.expires_at > now)
            .map(|row| PendingLink {
                user_id: row.user_id,
                external_id: row.external_id,
                username: row.username,
                display_name: row.display_name,
                avatar_hash: row.avatar_hash,
            }))
    }

    /// Links `account` to `user_id`, replacing any earlier link of the same
    /// provider for that member.
    pub async fn save_linked_account(
        &self,
        user_id: UserId,
        account: &LinkedAccount,
    ) -> Result<(), AccountLinkError> {
        let result = sqlx::query!(
            "INSERT INTO linked_accounts
                 (user_id, provider, external_id, username, display_name, linked_at,
                  avatar_updated_at)
             VALUES (?, ?, ?, ?, ?, ?, ?)
             ON CONFLICT (user_id, provider) DO UPDATE SET
                 external_id = excluded.external_id,
                 username = excluded.username,
                 display_name = excluded.display_name,
                 linked_at = excluded.linked_at,
                 avatar_updated_at = excluded.avatar_updated_at",
            user_id,
            account.provider,
            account.external_id,
            account.username,
            account.display_name,
            account.linked_at,
            account.avatar_updated_at
        )
        .execute(&self.pool)
        .await;
        match result {
            Ok(_) => Ok(()),
            Err(sqlx::Error::Database(error)) if error.is_unique_violation() => {
                Err(AccountLinkError::TakenByAnotherMember)
            }
            Err(error) => Err(error.into()),
        }
    }

    pub async fn linked_accounts(&self, user_id: UserId) -> anyhow::Result<Vec<LinkedAccount>> {
        let rows = sqlx::query_as!(
            LinkedAccount,
            "SELECT provider, external_id, username, display_name, linked_at,
                    avatar_updated_at
             FROM linked_accounts WHERE user_id = ? ORDER BY provider",
            user_id
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    /// Forgets the stored picture after its file could not be written.
    pub async fn clear_linked_avatar(&self, user_id: UserId, provider: &str) -> anyhow::Result<()> {
        sqlx::query!(
            "UPDATE linked_accounts SET avatar_updated_at = NULL
             WHERE user_id = ? AND provider = ?",
            user_id,
            provider
        )
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// Whether `user_id` has a stored picture for `provider`.
    pub async fn has_linked_avatar(&self, user_id: UserId, provider: &str) -> anyhow::Result<bool> {
        let row = sqlx::query!(
            "SELECT avatar_updated_at FROM linked_accounts WHERE user_id = ? AND provider = ?",
            user_id,
            provider
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.is_some_and(|row| row.avatar_updated_at.is_some()))
    }

    /// Whether there was a link to remove.
    pub async fn unlink_account(&self, user_id: UserId, provider: &str) -> anyhow::Result<bool> {
        let result = sqlx::query!(
            "DELETE FROM linked_accounts WHERE user_id = ? AND provider = ?",
            user_id,
            provider
        )
        .execute(&self.pool)
        .await?;
        Ok(result.rows_affected() > 0)
    }
}
