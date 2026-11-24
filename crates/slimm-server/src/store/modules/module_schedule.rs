// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The `schedule` capability's state: the module's own principal, the channel
//! its scheduled runs may post in, and when each scheduled command last ran.
//!
//! The principal is an `is_bot` user with no token and no session, so it can
//! author messages and be granted a channel like any bot, and nothing can sign
//! in as it.

use std::collections::HashMap;

use anyhow::Context;

use super::super::{Store, now_ms};
use crate::ids::{ChannelId, UserId};
use crate::limits::MAX_USERNAME_CHARS;
use crate::permissions::Permissions;
use crate::store::category_overwrites::mark_unsynced;
use crate::store::permissions::channel_overwrites::set_overwrite;

impl Store {
    /// The module's principal, created on first need and kept across
    /// updates; uninstalling removes it. Its display name follows the module's name.
    pub async fn ensure_module_bot(&self, module_id: &str, name: &str) -> anyhow::Result<UserId> {
        let mut tx = self.begin_write().await?;
        let existing = sqlx::query_scalar!(
            r#"SELECT bot_user_id AS "id: UserId" FROM installed_modules WHERE id = ?"#,
            module_id
        )
        .fetch_optional(&mut *tx)
        .await?
        .context("module is not installed")?;
        // A principal deleted behind the module's back is replaced, not revived.
        let existing = match existing {
            Some(id) => sqlx::query_scalar!(
                r#"SELECT 1 AS "one!: i64" FROM users WHERE id = ? AND deleted_at IS NULL"#,
                id
            )
            .fetch_optional(&mut *tx)
            .await?
            .map(|_| id),
            None => None,
        };
        if let Some(id) = existing {
            sqlx::query!("UPDATE users SET display_name = ? WHERE id = ?", name, id)
                .execute(&mut *tx)
                .await?;
            tx.commit().await?;
            return Ok(id);
        }
        let id = UserId::generate();
        let username = principal_username(module_id, id);
        let now = now_ms();
        sqlx::query!(
            "INSERT INTO users (id, username, display_name, created_at, is_bot) VALUES (?, ?, ?, ?, 1)",
            id,
            username,
            name,
            now
        )
        .execute(&mut *tx)
        .await?;
        sqlx::query!(
            "UPDATE installed_modules SET bot_user_id = ? WHERE id = ?",
            id,
            module_id
        )
        .execute(&mut *tx)
        .await?;
        tx.commit().await?;
        self.touch_modules();
        Ok(id)
    }

    /// `Ok(false)` if the module is not installed.
    pub async fn set_module_schedule_channel(
        &self,
        module_id: &str,
        channel: Option<ChannelId>,
    ) -> anyhow::Result<bool> {
        let affected = sqlx::query!(
            "UPDATE installed_modules SET schedule_channel_id = ? WHERE id = ?",
            channel,
            module_id
        )
        .execute(&self.pool)
        .await?
        .rows_affected();
        Ok(affected > 0)
    }

    /// Points the module's schedule at `new` (or at nothing), moving the bot's `post` grant with it
    /// in one transaction; the grant on the old channel goes only if it is exactly what this wrote.
    pub async fn move_module_schedule_channel(
        &self,
        module_id: &str,
        bot: UserId,
        new: Option<ChannelId>,
        post: Permissions,
    ) -> anyhow::Result<ScheduleMove> {
        let mut tx = self.begin_write().await?;
        let Some(old) = sqlx::query_scalar!(
            r#"SELECT schedule_channel_id AS "id: ChannelId" FROM installed_modules WHERE id = ?"#,
            module_id
        )
        .fetch_optional(&mut *tx)
        .await?
        else {
            return Ok(ScheduleMove::NotInstalled);
        };
        if let Some(new) = new.filter(|new| Some(*new) != old) {
            let held = member_overwrite(&mut tx, new, bot).await?;
            let (allow, deny) = held.unwrap_or((Permissions::NONE, Permissions::NONE));
            if deny.intersects(post) {
                return Ok(ScheduleMove::Denied);
            }
            let allow = allow.union(post);
            set_overwrite(&mut *tx, new, "member", bot.0, allow, deny).await?;
            mark_unsynced(&mut *tx, new).await?;
            super::super::voice_rooms::copy_lobby_overwrites_into_rooms(&mut tx, new).await?;
        }
        if let Some(old) = old.filter(|old| Some(*old) != new)
            && member_overwrite(&mut tx, old, bot).await? == Some((post, Permissions::NONE))
        {
            {
                let bot_id = bot.0;
                sqlx::query!(
                    "DELETE FROM channel_overwrites
                     WHERE channel_id = ? AND target_type = 'member' AND target_id = ?",
                    old,
                    bot_id
                )
                .execute(&mut *tx)
                .await?;
                mark_unsynced(&mut *tx, old).await?;
                super::super::voice_rooms::copy_lobby_overwrites_into_rooms(&mut tx, old).await?;
            }
        }
        sqlx::query!(
            "UPDATE installed_modules SET schedule_channel_id = ? WHERE id = ?",
            new,
            module_id
        )
        .execute(&mut *tx)
        .await?;
        tx.commit().await?;
        self.touch_modules();
        Ok(ScheduleMove::Moved)
    }

    /// Replaces the module's recorded schedules, outside an install.
    pub async fn set_module_schedules(
        &self,
        module_id: &str,
        schedules: &[crate::store::ModuleSchedule],
    ) -> anyhow::Result<bool> {
        let json = serde_json::to_string(schedules)?;
        let affected = sqlx::query!(
            "UPDATE installed_modules SET schedules = ? WHERE id = ?",
            json,
            module_id
        )
        .execute(&self.pool)
        .await?
        .rows_affected();
        Ok(affected > 0)
    }

    /// When each of the module's scheduled commands last ran, in epoch ms.
    pub async fn module_schedule_runs(
        &self,
        module_id: &str,
    ) -> anyhow::Result<HashMap<String, i64>> {
        let rows = sqlx::query!(
            r#"SELECT command AS "command!", last_run_at AS "last_run_at!"
               FROM module_schedule_runs WHERE module_id = ?"#,
            module_id
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .into_iter()
            .map(|r| (r.command, r.last_run_at))
            .collect())
    }

    pub async fn record_module_schedule_run(
        &self,
        module_id: &str,
        command: &str,
        at: i64,
    ) -> anyhow::Result<()> {
        sqlx::query!(
            "INSERT INTO module_schedule_runs (module_id, command, last_run_at) VALUES (?, ?, ?)
             ON CONFLICT (module_id, command) DO UPDATE SET last_run_at = excluded.last_run_at",
            module_id,
            command,
            at
        )
        .execute(&self.pool)
        .await?;
        Ok(())
    }
}

/// Unique by construction (the id's tail), so it can never collide with a
/// person's name; the display name is what members read.
pub(in crate::store) fn principal_username(module_id: &str, id: UserId) -> String {
    let tail = id.0.simple().to_string();
    let tail = &tail[tail.len() - 8..];
    let room = MAX_USERNAME_CHARS - "module--".len() - tail.len();
    let stem: String = module_id.chars().take(room).collect();
    format!("module-{stem}-{tail}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_principal_username_fits_and_keeps_the_module_id_readable() {
        let id = UserId::generate();
        let short = principal_username("homelab", id);
        assert!(short.starts_with("module-homelab-"), "{short}");
        let long = principal_username(&"x".repeat(64), id);
        assert_eq!(long.chars().count(), MAX_USERNAME_CHARS);
    }
}

/// How [`Store::move_module_schedule_channel`] ended.
#[derive(Debug, PartialEq, Eq)]
pub enum ScheduleMove {
    Moved,
    NotInstalled,
    /// The bot is denied posting on the new channel; nothing changed.
    Denied,
}

async fn member_overwrite(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    channel: ChannelId,
    user: UserId,
) -> anyhow::Result<Option<(Permissions, Permissions)>> {
    let user_id = user.0;
    let row = sqlx::query!(
        r#"SELECT allow AS "allow!: Permissions", deny AS "deny!: Permissions"
           FROM channel_overwrites
           WHERE channel_id = ? AND target_type = 'member' AND target_id = ?"#,
        channel,
        user_id
    )
    .fetch_optional(&mut **tx)
    .await?;
    Ok(row.map(|r| (r.allow, r.deny)))
}
