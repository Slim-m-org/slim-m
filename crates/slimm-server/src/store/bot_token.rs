// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Re-issuing a bot's token: an administrator's answer to a lost credential.
//! See `docs/decisions/0083-bot-token-reissue-select-menus-and-forms.md`.

use crate::auth::{generate_secret, hash_secret};
use crate::ids::{DeviceId, SessionId, UserId};

use super::bots::{BOT_TOKEN_PREFIX, Bot};
use super::moderation_audit::{ModerationAction, ModerationAudit, record_moderation_audit};
use super::sessions::revoke_session_rows;
use super::{Store, now_ms};

/// A bot's fresh token, the only time it is legible, and the sessions the old
/// one held. The caller must publish `Event::SessionRevoked` for each.
pub struct ReissuedToken {
    pub bot: Bot,
    pub token: String,
    pub revoked: Vec<SessionId>,
}

pub enum ReissueError {
    NoSuchBot,
    /// A removed bot gets its token back with the member, not before.
    Removed,
    Internal(anyhow::Error),
}

impl From<sqlx::Error> for ReissueError {
    fn from(err: sqlx::Error) -> Self {
        Self::Internal(err.into())
    }
}

impl From<anyhow::Error> for ReissueError {
    fn from(err: anyhow::Error) -> Self {
        Self::Internal(err)
    }
}

impl Store {
    /// Revokes whatever token the bot holds and mints a new one, in one
    /// transaction so a failure leaves the old token live. The account, its
    /// role and everything it authored are kept.
    pub async fn reissue_bot_token(
        &self,
        bot_id: UserId,
        reissued_by: UserId,
    ) -> Result<ReissuedToken, ReissueError> {
        let token = format!("{BOT_TOKEN_PREFIX}{}", generate_secret());
        let token_hash = hash_secret(&token);
        let (device_id, session_id) = (DeviceId::generate(), SessionId::generate());
        let now = now_ms();

        let mut tx = self.begin_write().await?;
        let account = sqlx::query!(
            r#"SELECT display_name,
                      EXISTS (SELECT 1 FROM space_removals WHERE user_id = users.id)
                          AS "removed!: bool"
               FROM users WHERE id = ? AND is_bot = 1 AND deleted_at IS NULL"#,
            bot_id
        )
        .fetch_optional(&mut *tx)
        .await?
        .ok_or(ReissueError::NoSuchBot)?;
        if account.removed {
            return Err(ReissueError::Removed);
        }

        let old = sqlx::query!(
            r#"SELECT session_id AS "session_id!: SessionId"
               FROM bot_tokens WHERE bot_user_id = ? AND revoked_at IS NULL"#,
            bot_id
        )
        .fetch_all(&mut *tx)
        .await?;
        sqlx::query!(
            "UPDATE bot_tokens SET revoked_at = ? WHERE bot_user_id = ? AND revoked_at IS NULL",
            now,
            bot_id
        )
        .execute(&mut *tx)
        .await?;
        let mut revoked = Vec::with_capacity(old.len());
        for row in old {
            revoke_session_rows(&mut tx, row.session_id, now).await?;
            revoked.push(row.session_id);
        }

        sqlx::query!(
            "INSERT INTO devices (id, user_id, name, created_at) VALUES (?, ?, ?, ?)",
            device_id,
            bot_id,
            account.display_name,
            now
        )
        .execute(&mut *tx)
        .await?;
        sqlx::query!(
            "INSERT INTO sessions (id, user_id, device_id, created_at) VALUES (?, ?, ?, ?)",
            session_id,
            bot_id,
            device_id,
            now
        )
        .execute(&mut *tx)
        .await?;
        sqlx::query!(
            "INSERT INTO bot_tokens
               (token_hash, bot_user_id, session_id, name, created_by, created_at)
             VALUES (?, ?, ?, ?, ?, ?)",
            token_hash,
            bot_id,
            session_id,
            account.display_name,
            reissued_by,
            now
        )
        .execute(&mut *tx)
        .await?;
        record_moderation_audit(
            &mut tx,
            ModerationAudit {
                actor_id: reissued_by,
                subject_id: bot_id,
                action: ModerationAction::BotTokenReissue,
                reason: None,
                until: None,
                created_at: now,
            },
        )
        .await?;
        tx.commit().await?;

        let bot = self
            .list_bots(true)
            .await?
            .into_iter()
            .find(|b| b.user_id == bot_id)
            .ok_or(ReissueError::NoSuchBot)?;
        Ok(ReissuedToken {
            bot,
            token,
            revoked,
        })
    }
}
