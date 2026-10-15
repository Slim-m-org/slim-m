// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The `schedule` capability's state: the module's own principal, the channel
//! its scheduled runs may post in, and when each scheduled command last ran.
//!
//! The principal is an `is_bot` user with no token and no session, so it can
//! author messages and be granted a channel like any bot, and nothing can sign
//! in as it.

use std::collections::HashMap;

use anyhow::Context;

use super::{Store, now_ms};
use crate::ids::{ChannelId, UserId};
use crate::limits::MAX_USERNAME_CHARS;

impl Store {
    /// The module's principal, created on first need and kept across
    /// reinstalls; its display name follows the module's name.
    pub async fn ensure_module_bot(&self, module_id: &str, name: &str) -> anyhow::Result<UserId> {
        let mut tx = self.begin_write().await?;
        let existing = sqlx::query_scalar!(
            r#"SELECT bot_user_id AS "id: UserId" FROM installed_modules WHERE id = ?"#,
            module_id
        )
        .fetch_optional(&mut *tx)
        .await?
        .context("module is not installed")?;
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
fn principal_username(module_id: &str, id: UserId) -> String {
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
