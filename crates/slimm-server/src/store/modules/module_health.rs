// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The circuit breaker's state and the event queue's drop count, one row per
//! module in `module_health`. Cleared by the cascade on uninstall.

use std::collections::HashMap;

use super::super::Store;
use crate::ids::UserId;

/// What the admin's installed list shows about a module's background runs.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ModuleHealth {
    pub consecutive_failures: i64,
    pub disabled_reason: Option<String>,
    pub events_dropped: i64,
}

/// A module that may be sent a pushed event: enabled, with a principal and the approvals.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EventCandidate {
    pub module_id: String,
    pub bot_user_id: UserId,
}

impl Store {
    pub async fn module_health(&self) -> anyhow::Result<HashMap<String, ModuleHealth>> {
        let rows = sqlx::query!(
            r#"SELECT module_id AS "module_id!", consecutive_failures AS "consecutive_failures!",
                      disabled_reason, events_dropped AS "events_dropped!"
               FROM module_health"#
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .into_iter()
            .map(|r| {
                (
                    r.module_id,
                    ModuleHealth {
                        consecutive_failures: r.consecutive_failures,
                        disabled_reason: r.disabled_reason,
                        events_dropped: r.events_dropped,
                    },
                )
            })
            .collect())
    }

    /// Modules that are enabled, have a principal and the `events` approval,
    /// and subscribe to `event`. A coarse filter; the dispatcher re-checks.
    pub async fn module_event_candidates(
        &self,
        event: &str,
    ) -> anyhow::Result<Vec<EventCandidate>> {
        let needle = format!("\"{event}\"");
        let rows = sqlx::query!(
            r#"SELECT id AS "id!", bot_user_id AS "bot_user_id!: UserId" FROM installed_modules
               WHERE enabled = 1 AND bot_user_id IS NOT NULL
                 AND instr(subscriptions, ?) > 0
                 AND instr(approved_capabilities, '"events"') > 0
                 AND instr(approved_host_capabilities, '"events"') > 0"#,
            needle
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .into_iter()
            .map(|r| EventCandidate {
                module_id: r.id,
                bot_user_id: r.bot_user_id,
            })
            .collect())
    }

    /// A background run succeeded: the failure streak ends.
    pub async fn record_module_background_ok(&self, module_id: &str) -> anyhow::Result<()> {
        sqlx::query!(
            "UPDATE module_health SET consecutive_failures = 0
             WHERE module_id = ? AND consecutive_failures > 0",
            module_id
        )
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// A background run failed; returns the streak including this failure.
    pub async fn record_module_background_failure(&self, module_id: &str) -> anyhow::Result<i64> {
        let streak = sqlx::query_scalar!(
            r#"INSERT INTO module_health (module_id, consecutive_failures) VALUES (?, 1)
               ON CONFLICT (module_id) DO UPDATE SET consecutive_failures = consecutive_failures + 1
               RETURNING consecutive_failures AS "streak!: i64""#,
            module_id
        )
        .fetch_one(&self.pool)
        .await?;
        Ok(streak)
    }

    /// Disables the module and stores why, once. `false` if it was already disabled.
    pub async fn disable_module_for_failures(
        &self,
        module_id: &str,
        reason: &str,
    ) -> anyhow::Result<bool> {
        let mut tx = self.begin_write().await?;
        let disabled = sqlx::query!(
            "UPDATE installed_modules SET enabled = 0 WHERE id = ? AND enabled = 1",
            module_id
        )
        .execute(&mut *tx)
        .await?
        .rows_affected();
        if disabled > 0 {
            sqlx::query!(
                "UPDATE module_health SET disabled_reason = ? WHERE module_id = ?",
                reason,
                module_id
            )
            .execute(&mut *tx)
            .await?;
        }
        tx.commit().await?;
        Ok(disabled > 0)
    }

    pub async fn add_module_events_dropped(
        &self,
        module_id: &str,
        dropped: i64,
    ) -> anyhow::Result<()> {
        sqlx::query!(
            "INSERT INTO module_health (module_id, events_dropped) VALUES (?, ?)
             ON CONFLICT (module_id) DO UPDATE SET events_dropped = events_dropped + excluded.events_dropped",
            module_id,
            dropped
        )
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// An admin re-enabled the module: the streak and the stated reason end.
    pub(in crate::store) async fn reset_module_breaker(
        &self,
        module_id: &str,
    ) -> anyhow::Result<()> {
        sqlx::query!(
            "UPDATE module_health SET consecutive_failures = 0, disabled_reason = NULL
             WHERE module_id = ?",
            module_id
        )
        .execute(&self.pool)
        .await?;
        Ok(())
    }
}
