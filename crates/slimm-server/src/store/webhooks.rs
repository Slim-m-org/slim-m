// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Incoming webhooks: a user-shaped principal with no session and no roles.
//!
//! See `docs/decisions/0030-incoming-webhooks.md`. Two things depart from
//! `docs/decisions/0028-bot-accounts.md`'s bot shape, and they are the whole
//! of what makes this module different from `bots.rs`:
//!
//! **No session.** [`Store::authenticate_webhook`] returns a
//! [`WebhookContext`], never a [`super::sessions::SessionContext`] - a
//! session is what makes a credential able to *read*, and a webhook must
//! never read. Nothing in this module can produce one, so no `Authed`
//! extractor can ever accept a webhook token; `tests/webhooks.rs` asserts
//! that structurally.
//!
//! **No roles.** [`super::permissions`]'s role loader returns an empty
//! context for any `is_webhook` principal before it even asks which roles
//! that id holds, so a webhook cannot inherit `@everyone`'s grant either, not
//! even by accident. That one guard is what makes "no MENTION_EVERYONE, no
//! ADMINISTRATOR, never counted as an administrator" true everywhere
//! permissions are evaluated, rather than a rule every caller has to
//! remember on its own.

use crate::auth::{generate_secret, hash_secret};
use crate::ids::{ChannelId, MessageId, UserId, WebhookId};

use super::moderation_audit::{ModerationAction, ModerationAudit, record_moderation_audit};
use super::{Store, now_ms};

/// A webhook, as an operator will see it once the admin surface exists.
/// Carries no secret.
#[derive(Debug, Clone)]
pub struct Webhook {
    pub id: WebhookId,
    /// The `users.id` this webhook posts as - a message's `author_id`, once
    /// it has posted one. Exposed for the same reason `Bot::user_id` is: a
    /// caller correlates a webhook with what it wrote through this, not
    /// through [`WebhookId`], which never appears on a message at all.
    pub principal_id: UserId,
    pub channel_id: ChannelId,
    pub label: String,
    pub created_at: i64,
    pub last_delivery_at: Option<i64>,
    /// Who minted this webhook, for the admin surface's listing. `None` if
    /// that admin's own account has since been deleted; the webhook itself
    /// keeps working either way.
    pub created_by: Option<UserId>,
    pub created_by_display_name: Option<String>,
}

/// A newly minted webhook and the one time its token is ever legible.
pub struct NewWebhook {
    pub webhook: Webhook,
    pub token: String,
}

/// What a presented `(webhook_id, token)` pair resolves to: enough to post as
/// this webhook's principal in its one fixed channel, and nothing else. Not a
/// [`super::sessions::SessionContext`] and cannot become one - see this
/// module's own doc.
pub struct WebhookContext {
    pub principal_id: UserId,
    pub channel_id: ChannelId,
}

impl Store {
    /// Mints a webhook and its first token in one transaction, the same
    /// "nothing useful without one" shape [`Store::create_bot`] uses.
    ///
    /// `label` becomes both the admin-facing name and the principal's
    /// `display_name`; the principal's `username` is generated rather than
    /// chosen, since nothing ever addresses a webhook by it - see this
    /// module's own doc for why the account still needs one at all.
    pub async fn create_webhook(
        &self,
        channel_id: ChannelId,
        label: &str,
        created_by: UserId,
    ) -> anyhow::Result<NewWebhook> {
        let webhook_id = WebhookId::generate();
        let user_id = UserId::generate();
        let token = generate_secret();
        let token_hash = hash_secret(&token);
        let now = now_ms();
        let username = format!("webhook-{user_id}");

        let mut tx = self.begin_write().await?;
        sqlx::query!(
            "INSERT INTO users (id, username, display_name, created_at, is_webhook)
             VALUES (?, ?, ?, ?, 1)",
            user_id,
            username,
            label,
            now
        )
        .execute(&mut *tx)
        .await?;
        sqlx::query!(
            "INSERT INTO webhooks (id, user_id, channel_id, token_hash, label, created_at, created_by)
             VALUES (?, ?, ?, ?, ?, ?, ?)",
            webhook_id,
            user_id,
            channel_id,
            token_hash,
            label,
            now,
            created_by
        )
        .execute(&mut *tx)
        .await?;
        record_moderation_audit(
            &mut tx,
            ModerationAudit {
                actor_id: created_by,
                subject_id: user_id,
                action: ModerationAction::WebhookCreate,
                reason: None,
                until: None,
                created_at: now,
            },
        )
        .await?;
        let created_by_display_name =
            sqlx::query_scalar!("SELECT display_name FROM users WHERE id = ?", created_by)
                .fetch_optional(&mut *tx)
                .await?;
        tx.commit().await?;

        Ok(NewWebhook {
            webhook: Webhook {
                id: webhook_id,
                principal_id: user_id,
                channel_id,
                label: label.to_owned(),
                created_at: now,
                last_delivery_at: None,
                created_by: Some(created_by),
                created_by_display_name,
            },
            token,
        })
    }

    /// Webhooks in the deployment, newest first. Carries no secret. See
    /// [`Webhook::created_by`] for why `created_by_display_name` can be
    /// absent even for a webhook that has one.
    pub async fn list_webhooks(&self) -> anyhow::Result<Vec<Webhook>> {
        let rows = sqlx::query!(
            r#"SELECT w.id AS "id!: WebhookId", w.user_id AS "user_id!: UserId",
                      w.channel_id AS "channel_id!: ChannelId", w.label,
                      w.created_at, w.last_delivery_at,
                      w.created_by AS "created_by?: UserId",
                      creator.display_name AS "created_by_display_name?"
               FROM webhooks w
               LEFT JOIN users creator ON creator.id = w.created_by
               ORDER BY w.created_at DESC"#
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .into_iter()
            .map(|r| Webhook {
                id: r.id,
                principal_id: r.user_id,
                channel_id: r.channel_id,
                label: r.label,
                created_at: r.created_at,
                last_delivery_at: r.last_delivery_at,
                created_by: r.created_by,
                created_by_display_name: r.created_by_display_name,
            })
            .collect())
    }

    /// Renames a webhook, updating both the admin-facing label and the
    /// principal's `display_name` so the two stay in the same
    /// correspondence [`Store::create_webhook`] established. Returns `None`
    /// if no webhook by that id exists.
    pub async fn rename_webhook(
        &self,
        webhook_id: WebhookId,
        label: &str,
    ) -> anyhow::Result<Option<Webhook>> {
        let mut tx = self.begin_write().await?;
        let user_id = sqlx::query_scalar!(
            r#"SELECT user_id AS "user_id!: UserId" FROM webhooks WHERE id = ?"#,
            webhook_id
        )
        .fetch_optional(&mut *tx)
        .await?;
        let Some(user_id) = user_id else {
            return Ok(None);
        };
        sqlx::query!(
            "UPDATE webhooks SET label = ? WHERE id = ?",
            label,
            webhook_id
        )
        .execute(&mut *tx)
        .await?;
        sqlx::query!(
            "UPDATE users SET display_name = ? WHERE id = ?",
            label,
            user_id
        )
        .execute(&mut *tx)
        .await?;
        tx.commit().await?;
        self.webhook_by_id(webhook_id).await
    }

    /// A single webhook by id, in the shape [`Store::list_webhooks`] returns.
    async fn webhook_by_id(&self, webhook_id: WebhookId) -> anyhow::Result<Option<Webhook>> {
        let row = sqlx::query!(
            r#"SELECT w.id AS "id!: WebhookId", w.user_id AS "user_id!: UserId",
                      w.channel_id AS "channel_id!: ChannelId", w.label,
                      w.created_at, w.last_delivery_at,
                      w.created_by AS "created_by?: UserId",
                      creator.display_name AS "created_by_display_name?"
               FROM webhooks w
               LEFT JOIN users creator ON creator.id = w.created_by
               WHERE w.id = ?"#,
            webhook_id
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.map(|r| Webhook {
            id: r.id,
            principal_id: r.user_id,
            channel_id: r.channel_id,
            label: r.label,
            created_at: r.created_at,
            last_delivery_at: r.last_delivery_at,
            created_by: r.created_by,
            created_by_display_name: r.created_by_display_name,
        }))
    }

    /// Resolves a presented `(webhook_id, token)` pair, or `None` if the id
    /// is unknown, the token is wrong, or the webhook has been revoked - the
    /// three cases the delivery route must answer identically (a uniform
    /// 404), which is why this collapses them into one `None` rather than
    /// telling the caller which.
    pub async fn authenticate_webhook(
        &self,
        webhook_id: WebhookId,
        token: &str,
    ) -> anyhow::Result<Option<WebhookContext>> {
        let hash = hash_secret(token);
        let row = sqlx::query!(
            r#"SELECT user_id AS "user_id!: UserId", channel_id AS "channel_id!: ChannelId"
               FROM webhooks WHERE id = ? AND token_hash = ?"#,
            webhook_id,
            hash
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.map(|r| WebhookContext {
            principal_id: r.user_id,
            channel_id: r.channel_id,
        }))
    }

    /// Stamps `last_delivery_at` after a successful post. Not debounced the
    /// way a bot token's `last_used_at` is: a webhook fires orders of
    /// magnitude less often than a polling bot ever does, so a write per
    /// delivery costs nothing worth guarding against.
    pub async fn touch_webhook_delivery(&self, webhook_id: WebhookId) -> anyhow::Result<()> {
        let now = now_ms();
        sqlx::query!(
            "UPDATE webhooks SET last_delivery_at = ? WHERE id = ?",
            now,
            webhook_id
        )
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// Stores a webhook post's per-post `username` label against the message
    /// it landed on. Never written to `users.display_name` or returned as a
    /// message's `author_display_name` - see this module's own doc and the
    /// decision record's "`username` becomes a label" section. Called at
    /// most once per message, right after [`Store::send_message`] returns a
    /// fresh send.
    pub async fn set_webhook_message_username(
        &self,
        message_id: MessageId,
        username: &str,
    ) -> anyhow::Result<()> {
        sqlx::query!(
            "INSERT INTO webhook_message_usernames (message_id, username) VALUES (?, ?)",
            message_id,
            username
        )
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// The `username` label stored against `message_id`, or `None` if it was
    /// posted with none. The live frames read it per message; list and sync
    /// use [`Store::webhook_usernames_for_messages`].
    pub async fn webhook_message_username(
        &self,
        message_id: MessageId,
    ) -> anyhow::Result<Option<String>> {
        let username = sqlx::query_scalar!(
            "SELECT username FROM webhook_message_usernames WHERE message_id = ?",
            message_id
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(username)
    }

    /// The label for each of `message_ids` that has one, batched like
    /// [`Store::embeds_for_messages`]; messages with none are absent.
    pub async fn webhook_usernames_for_messages(
        &self,
        message_ids: &[MessageId],
    ) -> anyhow::Result<std::collections::HashMap<MessageId, String>> {
        if message_ids.is_empty() {
            return Ok(std::collections::HashMap::new());
        }
        let mut builder = sqlx::QueryBuilder::new(
            "SELECT message_id, username FROM webhook_message_usernames WHERE message_id IN (",
        );
        let mut separated = builder.separated(", ");
        for id in message_ids {
            separated.push_bind(*id);
        }
        builder.push(")");
        use sqlx::Row;
        let mut labels = std::collections::HashMap::new();
        for row in builder.build().fetch_all(&self.pool).await? {
            labels.insert(row.try_get("message_id")?, row.try_get("username")?);
        }
        Ok(labels)
    }

    /// Replaces a webhook's token in place and returns the new one, the only
    /// time it is legible. The row, and so the principal, is kept, so what
    /// the webhook already posted stays attributed to it; the old token stops
    /// resolving in the same transaction. `None` if no such webhook exists.
    pub async fn rotate_webhook(
        &self,
        webhook_id: WebhookId,
        rotated_by: UserId,
    ) -> anyhow::Result<Option<(Webhook, String)>> {
        let token = generate_secret();
        let token_hash = hash_secret(&token);
        let mut tx = self.begin_write().await?;
        let user_id = sqlx::query_scalar!(
            r#"UPDATE webhooks SET token_hash = ? WHERE id = ?
               RETURNING user_id AS "user_id!: UserId""#,
            token_hash,
            webhook_id
        )
        .fetch_optional(&mut *tx)
        .await?;
        let Some(user_id) = user_id else {
            return Ok(None);
        };
        record_moderation_audit(
            &mut tx,
            ModerationAudit {
                actor_id: rotated_by,
                subject_id: user_id,
                action: ModerationAction::WebhookRotate,
                reason: None,
                until: None,
                created_at: now_ms(),
            },
        )
        .await?;
        tx.commit().await?;
        Ok(self.webhook_by_id(webhook_id).await?.map(|w| (w, token)))
    }

    /// Revokes a webhook by deleting its row outright. There is no session
    /// and no socket to also close, so the row going away is the whole of
    /// it - simpler than [`Store::revoke_bot`], and immediate the same way.
    /// The principal's `users` row survives, so anything it already posted
    /// stays attributed. Returns `false` if no webhook by that id exists.
    pub async fn revoke_webhook(
        &self,
        webhook_id: WebhookId,
        revoked_by: UserId,
    ) -> anyhow::Result<bool> {
        let mut tx = self.begin_write().await?;
        let user_id = sqlx::query_scalar!(
            r#"SELECT user_id AS "user_id!: UserId" FROM webhooks WHERE id = ?"#,
            webhook_id
        )
        .fetch_optional(&mut *tx)
        .await?;
        let Some(user_id) = user_id else {
            return Ok(false);
        };
        sqlx::query!("DELETE FROM webhooks WHERE id = ?", webhook_id)
            .execute(&mut *tx)
            .await?;
        record_moderation_audit(
            &mut tx,
            ModerationAudit {
                actor_id: revoked_by,
                subject_id: user_id,
                action: ModerationAction::WebhookRevoke,
                reason: None,
                until: None,
                created_at: now_ms(),
            },
        )
        .await?;
        tx.commit().await?;
        Ok(true)
    }
}
