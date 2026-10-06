// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Bot accounts and their tokens.
//!
//! A bot is a user-shaped principal, not a parallel one: a row in `users` with
//! `is_bot` set, a membership, and roles. So authorship, authorization,
//! fan-out and moderation all reach a bot through the code paths they already
//! use for a person, and nothing here re-implements any of them. See
//! `docs/decisions/0028-bot-accounts.md`.
//!
//! Two things are specific to a bot, and they are the whole of this module.
//!
//! **A bot token resolves to a real session.** Creating one writes a `devices`
//! row and a `sessions` row exactly as a sign-in does, and the token points at
//! that session. That is what lets a bot mint a ws ticket, be revoked, and be
//! authorized per subscriber with no second code path - and it means revoking
//! a bot is [`Store::revoke_session`], the function that already does it.
//!
//! **The token does not rotate.** A bot is typically a container holding a
//! credential in an environment variable, with nowhere to persist a rotated
//! pair and nobody to sign in again when a response is lost. Rotation would
//! turn every dropped response into a dead bot. The mitigation for a
//! long-lived credential is revocation and audit, not a short TTL.
//!
//! A third thing lives here now: **a bot's managed role**. See
//! `docs/decisions/0028-bot-accounts.md`.

use crate::auth::{generate_secret, hash_secret};
use crate::ids::{DeviceId, RoleId, SessionId, UserId};
use crate::permissions::Permissions;

use super::moderation_audit::{ModerationAudit, record_moderation_audit};
use super::sessions::SessionContext;
use super::{Store, now_ms};

/// Marks a bot token in its plaintext, so the auth extractor can route a
/// presented credential to the right table without a second lookup on the
/// human hot path. Not a secret and not load-bearing for security - the hash
/// is what authenticates.
pub const BOT_TOKEN_PREFIX: &str = "slimbot_";

/// How stale `last_used_at` may get before a request bothers writing it.
///
/// A bot is a program and can call constantly, so stamping every request would
/// add a write per request to answer a question nobody asks to the second.
const LAST_USED_WRITE_AFTER_MS: i64 = 60 * 1000;

/// A bot, as an operator sees it in the admin surface. Carries no secret.
#[derive(Debug, Clone)]
pub struct Bot {
    pub user_id: UserId,
    pub username: String,
    pub display_name: String,
    pub created_at: i64,
    /// Null once the token has been revoked, so a listing can say whether this
    /// bot can currently do anything at all.
    pub token_name: Option<String>,
    pub token_last_used_at: Option<i64>,
    /// The bot's managed role and its permissions; the role outlives a revoke (ADR 0028).
    pub role_id: Option<RoleId>,
    pub permissions: Permissions,
}

/// A newly created bot and the one time its token is ever legible.
pub struct NewBot {
    pub bot: Bot,
    pub token: String,
}

/// Why creating a bot failed.
#[derive(Debug)]
pub enum CreateBotError {
    UsernameTaken,
    Internal(anyhow::Error),
}

impl From<sqlx::Error> for CreateBotError {
    fn from(err: sqlx::Error) -> Self {
        CreateBotError::Internal(err.into())
    }
}

/// Why changing a bot's permissions failed.
#[derive(Debug)]
pub enum UpdateBotPermissionsError {
    /// No bot by that id, or it has no managed role to change.
    NoSuchBot,
    Internal(anyhow::Error),
}

impl From<sqlx::Error> for UpdateBotPermissionsError {
    fn from(err: sqlx::Error) -> Self {
        UpdateBotPermissionsError::Internal(err.into())
    }
}

impl Store {
    /// Creates a bot, its managed role, and its first token, in one
    /// transaction. `permissions` is trusted, already validated by `http::bots`.
    pub async fn create_bot(
        &self,
        username: &str,
        display_name: &str,
        permissions: Permissions,
        created_by: UserId,
    ) -> Result<NewBot, CreateBotError> {
        let user_id = UserId::generate();
        let device_id = DeviceId::generate();
        let session_id = SessionId::generate();
        let role_id = RoleId::generate();
        let token = format!("{BOT_TOKEN_PREFIX}{}", generate_secret());
        let token_hash = hash_secret(&token);
        let now = now_ms();

        let mut tx = self.begin_write().await?;
        let inserted = sqlx::query!(
            "INSERT INTO users (id, username, display_name, created_at, is_bot)
             VALUES (?, ?, ?, ?, 1)",
            user_id,
            username,
            display_name,
            now
        )
        .execute(&mut *tx)
        .await;
        match inserted {
            Ok(_) => {}
            Err(sqlx::Error::Database(e)) if e.is_unique_violation() => {
                return Err(CreateBotError::UsernameTaken);
            }
            Err(e) => return Err(CreateBotError::Internal(e.into())),
        }

        sqlx::query!(
            "INSERT INTO devices (id, user_id, name, created_at) VALUES (?, ?, ?, ?)",
            device_id,
            user_id,
            display_name,
            now
        )
        .execute(&mut *tx)
        .await?;
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
            "INSERT INTO bot_tokens
               (token_hash, bot_user_id, session_id, name, created_by, created_at)
             VALUES (?, ?, ?, ?, ?, ?)",
            token_hash,
            user_id,
            session_id,
            display_name,
            created_by,
            now
        )
        .execute(&mut *tx)
        .await?;

        let permission_bits = permissions.bits();
        sqlx::query!(
            "INSERT INTO roles (id, name, permissions, is_everyone, created_at, managed_bot_id)
             VALUES (?, ?, ?, 0, ?, ?)",
            role_id,
            display_name,
            permission_bits,
            now,
            user_id
        )
        .execute(&mut *tx)
        .await?;
        sqlx::query!(
            "INSERT INTO member_roles (user_id, role_id) VALUES (?, ?)",
            user_id,
            role_id
        )
        .execute(&mut *tx)
        .await?;
        record_moderation_audit(
            &mut tx,
            ModerationAudit {
                actor_id: created_by,
                subject_id: user_id,
                action: "bot_create",
                reason: Some(&format!(
                    "role {role_id} created with permissions {permission_bits}"
                )),
                until: None,
                created_at: now,
            },
        )
        .await?;

        tx.commit().await?;

        Ok(NewBot {
            bot: Bot {
                user_id,
                username: username.to_owned(),
                display_name: display_name.to_owned(),
                created_at: now,
                token_name: Some(display_name.to_owned()),
                token_last_used_at: None,
                role_id: Some(role_id),
                permissions,
            },
            token,
        })
    }

    /// Bots in the deployment, newest first. No secrets.
    ///
    /// A bot removed from the Space is left out unless `include_removed` is
    /// set: it is gone from `GET /members` already, so keeping it here
    /// forever would answer "every bot ever minted" to a question that means
    /// "what has a credential on my deployment". A bot that is still a
    /// member is always included, even revoked, because it stays on the
    /// roster everywhere else and its authorship may still matter to
    /// whoever is reading this list. See `docs/decisions/0028-bot-accounts.md`.
    pub async fn list_bots(&self, include_removed: bool) -> anyhow::Result<Vec<Bot>> {
        let include_removed = i64::from(include_removed);
        let rows = sqlx::query!(
            r#"SELECT u.id AS "user_id!: UserId", u.username, u.display_name,
                      u.created_at,
                      t.name AS token_name, t.last_used_at,
                      r.id AS "role_id: RoleId", r.permissions AS "permissions: Permissions"
               FROM users u
               LEFT JOIN bot_tokens t
                 ON t.bot_user_id = u.id AND t.revoked_at IS NULL
               LEFT JOIN roles r ON r.managed_bot_id = u.id
               WHERE u.is_bot = 1 AND u.deleted_at IS NULL
                 AND (? = 1 OR NOT EXISTS (
                   SELECT 1 FROM space_removals sr WHERE sr.user_id = u.id
                 ))
               ORDER BY u.created_at DESC"#,
            include_removed
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .into_iter()
            .map(|r| Bot {
                user_id: r.user_id,
                username: r.username,
                display_name: r.display_name,
                created_at: r.created_at,
                token_name: r.token_name,
                token_last_used_at: r.last_used_at,
                role_id: r.role_id,
                permissions: r.permissions.unwrap_or(Permissions::NONE),
            })
            .collect())
    }

    /// Resolves a presented bot token to its session, or `None` if it is
    /// unknown, revoked, or its account is gone.
    ///
    /// Stamps `last_used_at` at most once per [`LAST_USED_WRITE_AFTER_MS`], so
    /// a chatty bot does not turn every read into a write.
    pub async fn authenticate_bot(&self, token: &str) -> anyhow::Result<Option<SessionContext>> {
        let hash = hash_secret(token);
        let row = sqlx::query!(
            r#"SELECT t.bot_user_id AS "user_id!: UserId",
                      t.session_id AS "session_id!: SessionId",
                      s.device_id AS "device_id!: DeviceId",
                      t.last_used_at
               FROM bot_tokens t
               JOIN sessions s ON s.id = t.session_id
               JOIN users u ON u.id = t.bot_user_id
               WHERE t.token_hash = ?
                 AND t.revoked_at IS NULL
                 AND s.revoked_at IS NULL
                 AND u.deleted_at IS NULL"#,
            hash
        )
        .fetch_optional(&self.pool)
        .await?;
        let Some(row) = row else {
            return Ok(None);
        };

        let now = now_ms();
        if row
            .last_used_at
            .is_none_or(|at| now - at > LAST_USED_WRITE_AFTER_MS)
        {
            sqlx::query!(
                "UPDATE bot_tokens SET last_used_at = ? WHERE token_hash = ?",
                now,
                hash
            )
            .execute(&self.pool)
            .await?;
        }

        Ok(Some(SessionContext {
            user_id: row.user_id,
            session_id: row.session_id,
            device_id: row.device_id,
        }))
    }

    /// Changes what a bot's managed role grants; `permissions` is already
    /// validated by `http::bots`. A revoked bot keeps its managed role (ADR 0028),
    /// so this still succeeds for one; `NoSuchBot` means no managed role exists.
    pub async fn update_bot_permissions(
        &self,
        bot_user_id: UserId,
        actor_id: UserId,
        permissions: Permissions,
    ) -> Result<Bot, UpdateBotPermissionsError> {
        let mut tx = self.begin_write().await?;
        let role_id = sqlx::query_scalar!(
            r#"SELECT id AS "id!: RoleId" FROM roles WHERE managed_bot_id = ?"#,
            bot_user_id
        )
        .fetch_optional(&mut *tx)
        .await?;
        let Some(role_id) = role_id else {
            return Err(UpdateBotPermissionsError::NoSuchBot);
        };

        let bits = permissions.bits();
        sqlx::query!(
            "UPDATE roles SET permissions = ? WHERE id = ?",
            bits,
            role_id
        )
        .execute(&mut *tx)
        .await?;

        let now = now_ms();
        record_moderation_audit(
            &mut tx,
            ModerationAudit {
                actor_id,
                subject_id: bot_user_id,
                action: "bot_permission_grant",
                reason: Some(&format!("role {role_id} permissions now {bits}")),
                until: None,
                created_at: now,
            },
        )
        .await?;
        tx.commit().await?;

        let bot = sqlx::query!(
            r#"SELECT u.id AS "user_id!: UserId", u.username, u.display_name, u.created_at,
                      t.name AS "token_name?", t.last_used_at AS "last_used_at?"
               FROM users u
               LEFT JOIN bot_tokens t ON t.bot_user_id = u.id AND t.revoked_at IS NULL
               WHERE u.id = ?"#,
            bot_user_id
        )
        .fetch_one(&self.pool)
        .await?;
        Ok(Bot {
            user_id: bot.user_id,
            username: bot.username,
            display_name: bot.display_name,
            created_at: bot.created_at,
            token_name: bot.token_name,
            token_last_used_at: bot.last_used_at,
            role_id: Some(role_id),
            permissions,
        })
    }

    /// Whether this user is a bot, for the badge the interface draws.
    pub async fn is_bot(&self, user_id: UserId) -> anyhow::Result<bool> {
        let row = sqlx::query!(
            "SELECT is_bot FROM users WHERE id = ? AND deleted_at IS NULL",
            user_id
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.map(|r| r.is_bot != 0).unwrap_or(false))
    }

    /// Whether this bot holds a token that has not been revoked.
    pub async fn bot_has_live_token(&self, bot_user_id: UserId) -> anyhow::Result<bool> {
        let row = sqlx::query_scalar!(
            r#"SELECT 1 AS "one!: i64" FROM bot_tokens
               WHERE bot_user_id = ? AND revoked_at IS NULL LIMIT 1"#,
            bot_user_id
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.is_some())
    }

    /// Revokes a bot's token and session. The account and its roles stay, so
    /// a role shared with a human is unaffected.
    ///
    /// Returns `None` if no bot by that id exists, and otherwise the sessions
    /// it revoked. The caller must publish
    /// [`crate::hub::Event::SessionRevoked`] for each.
    pub async fn revoke_bot(
        &self,
        bot_user_id: UserId,
        revoked_by: UserId,
    ) -> anyhow::Result<Option<Vec<SessionId>>> {
        let now = now_ms();
        let sessions = sqlx::query!(
            r#"SELECT session_id AS "session_id!: SessionId"
               FROM bot_tokens WHERE bot_user_id = ? AND revoked_at IS NULL"#,
            bot_user_id
        )
        .fetch_all(&self.pool)
        .await?;
        if sessions.is_empty() {
            return Ok(self.is_bot(bot_user_id).await?.then(Vec::new));
        }

        let mut tx = self.begin_write().await?;
        sqlx::query!(
            "UPDATE bot_tokens SET revoked_at = ? WHERE bot_user_id = ? AND revoked_at IS NULL",
            now,
            bot_user_id
        )
        .execute(&mut *tx)
        .await?;
        record_moderation_audit(
            &mut tx,
            ModerationAudit {
                actor_id: revoked_by,
                subject_id: bot_user_id,
                action: "bot_revoke",
                reason: None,
                until: None,
                created_at: now,
            },
        )
        .await?;
        tx.commit().await?;

        let mut revoked = Vec::with_capacity(sessions.len());
        for row in sessions {
            self.revoke_session(row.session_id).await?;
            revoked.push(row.session_id);
        }
        Ok(Some(revoked))
    }
}
