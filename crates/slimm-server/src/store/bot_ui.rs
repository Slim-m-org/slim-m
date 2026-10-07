// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A bot's registered menu entries and call controls. See
//! docs/decisions/0045-bot-contributed-ui.md.

use sqlx::Row;

use crate::bot_ui::{Surface, UiEntry, UiOption, UiRegistration};
use crate::ids::{ChannelId, UserId};
use crate::permissions::Permissions;

use super::Store;

/// One bot's entries a viewer of a channel may currently be offered.
#[derive(Debug, Clone)]
pub struct VisibleBotUi {
    pub bot_user_id: UserId,
    pub bot_username: String,
    pub bot_display_name: String,
    pub message_menu: Vec<UiEntry>,
    pub call_controls: Vec<UiEntry>,
}

impl Store {
    /// Replaces a bot's whole registration in one transaction.
    pub async fn set_bot_ui(&self, bot: UserId, reg: &UiRegistration) -> anyhow::Result<()> {
        let mut tx = self.begin_write().await?;
        sqlx::query("DELETE FROM bot_ui_entries WHERE bot_user_id = ?")
            .bind(bot)
            .execute(&mut *tx)
            .await?;
        let sets = [
            (Surface::MessageMenu, &reg.message_menu),
            (Surface::CallControl, &reg.call_controls),
        ];
        for (surface, entries) in sets {
            for (position, entry) in entries.iter().enumerate() {
                sqlx::query(
                    "INSERT INTO bot_ui_entries
                        (bot_user_id, surface, entry_id, label, icon, permission, position, options)
                     VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                )
                .bind(bot)
                .bind(surface.as_str())
                .bind(&entry.id)
                .bind(&entry.label)
                .bind(&entry.icon)
                .bind(entry.permission)
                .bind(position as i64)
                .bind(options_json(&entry.options)?)
                .execute(&mut *tx)
                .await?;
            }
        }
        tx.commit().await?;
        Ok(())
    }

    /// Whether `bot` is a live bot: a live token and not removed from the Space.
    pub async fn bot_is_live(&self, bot: UserId) -> anyhow::Result<bool> {
        let row = sqlx::query(
            "SELECT 1 FROM users u
             WHERE u.id = ? AND u.is_bot = 1 AND u.deleted_at IS NULL
               AND EXISTS (SELECT 1 FROM bot_tokens t WHERE t.bot_user_id = u.id AND t.revoked_at IS NULL)
               AND NOT EXISTS (SELECT 1 FROM space_removals sr WHERE sr.user_id = u.id)",
        )
        .bind(bot)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.is_some())
    }

    /// One registered entry, or `None` when the bot has not registered it.
    pub async fn bot_ui_entry(
        &self,
        bot: UserId,
        surface: Surface,
        entry_id: &str,
    ) -> anyhow::Result<Option<UiEntry>> {
        let row = sqlx::query(
            "SELECT entry_id, label, icon, permission, options FROM bot_ui_entries
             WHERE bot_user_id = ? AND surface = ? AND entry_id = ?",
        )
        .bind(bot)
        .bind(surface.as_str())
        .bind(entry_id)
        .fetch_optional(&self.pool)
        .await?;
        row.map(|r| entry_of(&r)).transpose()
    }

    /// Every bot's entries the caller may be offered in `channel_id`. A bot
    /// must hold `VIEW_CHANNEL` there, and an entry that names a permission is
    /// left out for a caller who lacks it.
    pub async fn visible_bot_ui(
        &self,
        channel_id: ChannelId,
        caller: Permissions,
    ) -> anyhow::Result<Vec<VisibleBotUi>> {
        let rows = sqlx::query(
            "SELECT u.id AS bot_id, u.username, u.display_name, e.surface,
                    e.entry_id, e.label, e.icon, e.permission, e.options
             FROM bot_ui_entries e
             JOIN users u ON u.id = e.bot_user_id
             WHERE u.is_bot = 1 AND u.deleted_at IS NULL
               AND EXISTS (SELECT 1 FROM bot_tokens t WHERE t.bot_user_id = u.id AND t.revoked_at IS NULL)
               AND NOT EXISTS (SELECT 1 FROM space_removals sr WHERE sr.user_id = u.id)
             ORDER BY u.display_name ASC, u.id ASC, e.surface ASC, e.position ASC",
        )
        .fetch_all(&self.pool)
        .await?;
        let mut out: Vec<VisibleBotUi> = Vec::new();
        let mut can_view: std::collections::HashMap<UserId, bool> = Default::default();
        for row in rows {
            let bot_id: UserId = row.try_get("bot_id")?;
            let entry = entry_of(&row)?;
            if let Some(bit) = entry.permission
                && !caller.contains(Permissions::from_bits(bit))
            {
                continue;
            }
            let allowed = match can_view.get(&bot_id) {
                Some(allowed) => *allowed,
                None => {
                    let allowed = self
                        .permissions_in_channel(bot_id, channel_id)
                        .await?
                        .contains(Permissions::VIEW_CHANNEL);
                    can_view.insert(bot_id, allowed);
                    allowed
                }
            };
            if !allowed {
                continue;
            }
            if out.last().is_none_or(|last| last.bot_user_id != bot_id) {
                out.push(VisibleBotUi {
                    bot_user_id: bot_id,
                    bot_username: row.try_get("username")?,
                    bot_display_name: row.try_get("display_name")?,
                    message_menu: Vec::new(),
                    call_controls: Vec::new(),
                });
            }
            let Some(current) = out.last_mut() else {
                continue;
            };
            let surface: String = row.try_get("surface")?;
            match Surface::parse(&surface) {
                Some(Surface::MessageMenu) => current.message_menu.push(entry),
                Some(Surface::CallControl) => current.call_controls.push(entry),
                None => {}
            }
        }
        Ok(out)
    }
}

fn entry_of(row: &sqlx::sqlite::SqliteRow) -> anyhow::Result<UiEntry> {
    Ok(UiEntry {
        id: row.try_get("entry_id")?,
        label: row.try_get("label")?,
        icon: row.try_get("icon")?,
        permission: row.try_get("permission")?,
        options: match row.try_get::<Option<String>, _>("options")? {
            Some(json) => serde_json::from_str(&json)?,
            None => Vec::new(),
        },
    })
}

/// NULL for a plain button, so a row written before options existed reads the same.
fn options_json(options: &[UiOption]) -> anyhow::Result<Option<String>> {
    if options.is_empty() {
        return Ok(None);
    }
    Ok(Some(serde_json::to_string(options)?))
}
