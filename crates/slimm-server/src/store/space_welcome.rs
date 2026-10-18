// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The optional welcome message posted when someone joins. Off by default.

use anyhow::Context;

use super::{Store, now_ms};
use crate::ids::{ChannelId, UserId};

/// Longest template, in characters. Enforced in Rust so it can move without a migration.
pub const MAX_WELCOME_MESSAGE_CHARS: usize = 500;

#[derive(Debug, Clone, Default)]
pub struct SpaceWelcome {
    pub enabled: bool,
    pub channel_id: Option<ChannelId>,
    pub message: String,
}

impl Store {
    pub async fn space_welcome(&self) -> anyhow::Result<SpaceWelcome> {
        let row = sqlx::query!(
            r#"SELECT welcome_enabled AS "enabled!: bool",
                      welcome_channel_id AS "channel_id: ChannelId",
                      welcome_message AS "message!: String"
               FROM space_settings WHERE id = 1"#
        )
        .fetch_optional(&self.pool)
        .await
        .context("read space welcome")?;
        Ok(row
            .map(|r| SpaceWelcome {
                enabled: r.enabled,
                channel_id: r.channel_id,
                message: r.message,
            })
            .unwrap_or_default())
    }

    pub async fn set_space_welcome(&self, welcome: &SpaceWelcome) -> anyhow::Result<()> {
        let now = now_ms();
        sqlx::query!(
            "UPDATE space_settings
             SET welcome_enabled = ?, welcome_channel_id = ?, welcome_message = ?, updated_at = ?
             WHERE id = 1",
            welcome.enabled,
            welcome.channel_id,
            welcome.message,
            now
        )
        .execute(&self.pool)
        .await
        .context("set space welcome")?;
        Ok(())
    }

    /// The webhook-shaped principal welcome posts are attributed to, made on first use.
    pub async fn welcome_author(&self) -> anyhow::Result<UserId> {
        let mut tx = self.begin_write().await?;
        let existing = sqlx::query_scalar!(
            r#"SELECT welcome_author_id AS "id: UserId" FROM space_settings WHERE id = 1"#
        )
        .fetch_one(&mut *tx)
        .await?;
        if let Some(id) = existing {
            tx.commit().await?;
            return Ok(id);
        }
        let id = UserId::generate();
        let username = format!("welcome-{id}");
        let now = now_ms();
        sqlx::query!(
            "INSERT INTO users (id, username, display_name, created_at, is_webhook)
             VALUES (?, ?, 'Welcome', ?, 1)",
            id,
            username,
            now
        )
        .execute(&mut *tx)
        .await?;
        sqlx::query!(
            "UPDATE space_settings SET welcome_author_id = ? WHERE id = 1",
            id
        )
        .execute(&mut *tx)
        .await?;
        tx.commit().await?;
        Ok(id)
    }
}
