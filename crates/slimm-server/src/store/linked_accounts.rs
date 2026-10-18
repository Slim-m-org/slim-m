// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Accounts members link from elsewhere (Discord), and the one-time states
//! that tie an OAuth callback back to the member who started it.

use super::{Store, now_ms};
use crate::ids::UserId;

/// A linked account as shown on a profile.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LinkedAccount {
    pub provider: String,
    pub external_id: String,
    pub username: String,
    pub display_name: Option<String>,
    pub linked_at: i64,
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

    /// Links `account` to `user_id`, replacing any earlier link of the same
    /// provider for that member.
    pub async fn save_linked_account(
        &self,
        user_id: UserId,
        account: &LinkedAccount,
    ) -> Result<(), AccountLinkError> {
        let result = sqlx::query!(
            "INSERT INTO linked_accounts
                 (user_id, provider, external_id, username, display_name, linked_at)
             VALUES (?, ?, ?, ?, ?, ?)
             ON CONFLICT (user_id, provider) DO UPDATE SET
                 external_id = excluded.external_id,
                 username = excluded.username,
                 display_name = excluded.display_name,
                 linked_at = excluded.linked_at",
            user_id,
            account.provider,
            account.external_id,
            account.username,
            account.display_name,
            account.linked_at
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
            "SELECT provider, external_id, username, display_name, linked_at
             FROM linked_accounts WHERE user_id = ? ORDER BY provider",
            user_id
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
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
