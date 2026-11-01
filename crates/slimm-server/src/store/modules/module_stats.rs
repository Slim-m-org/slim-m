// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What a module's commands have done lately, and what its `kv.store` holds,
//! for the admin's Dock screen. One bounded row per (module, command); the
//! foreign key clears them with the module.

use std::collections::HashMap;

use super::super::Store;

/// Longest error text kept; the column checks the same bound.
const MAX_ERROR_CHARS: usize = 300;

/// How one run ended, as far as the module's health is concerned.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RunResult {
    Ok,
    Failed(String),
}

/// A command's recorded history.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ModuleRunStat {
    pub command: String,
    pub run_count: i64,
    pub failure_count: i64,
    pub last_run_at: i64,
    pub last_ok_at: Option<i64>,
    pub failing_since: Option<i64>,
    pub last_error: Option<String>,
    pub last_error_at: Option<i64>,
    pub last_duration_ms: i64,
    pub max_duration_ms: i64,
    /// Fuel the last run used, absent when it could not be read; and the most any run has used.
    pub last_fuel_used: Option<i64>,
    pub max_fuel_used: i64,
}

/// When one run happened, how long it took and how much fuel it burned.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RunTiming {
    pub at: i64,
    pub duration_ms: i64,
    pub fuel_used: Option<i64>,
}

/// A run with no fuel reading, as every caller that does not meter one has.
impl From<(i64, i64)> for RunTiming {
    fn from((at, duration_ms): (i64, i64)) -> Self {
        RunTiming {
            at,
            duration_ms,
            fuel_used: None,
        }
    }
}

/// How much of its `kv.store` allowance a module is using.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct StorageUsage {
    pub entries: i64,
    pub bytes: i64,
}

impl Store {
    /// Records one run of `command`. A failure starts (or keeps) the
    /// "failing since" mark; a success clears it.
    pub async fn record_module_run(
        &self,
        module_id: &str,
        command: &str,
        result: &RunResult,
        timing: impl Into<RunTiming>,
    ) -> anyhow::Result<()> {
        let RunTiming {
            at,
            duration_ms,
            fuel_used,
        } = timing.into();
        let max_fuel = fuel_used.unwrap_or(0);
        let (failed, error) = match result {
            RunResult::Ok => (0_i64, None),
            RunResult::Failed(text) => (
                1,
                Some(text.chars().take(MAX_ERROR_CHARS).collect::<String>()),
            ),
        };
        let ok_at = (failed == 0).then_some(at);
        let error_at = (failed == 1).then_some(at);
        let failing_since = (failed == 1).then_some(at);
        sqlx::query!(
            "INSERT INTO module_run_stats
                 (module_id, command, run_count, failure_count, last_run_at, last_ok_at,
                  failing_since, last_error, last_error_at, last_duration_ms, max_duration_ms,
                  last_fuel_used, max_fuel_used)
             VALUES (?, ?, 1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
             ON CONFLICT (module_id, command) DO UPDATE SET
                 run_count = run_count + 1,
                 failure_count = failure_count + excluded.failure_count,
                 last_run_at = excluded.last_run_at,
                 last_ok_at = COALESCE(excluded.last_ok_at, last_ok_at),
                 failing_since = CASE WHEN excluded.failure_count = 0 THEN NULL
                                      ELSE COALESCE(failing_since, excluded.failing_since) END,
                 last_error = CASE WHEN excluded.failure_count = 0 THEN last_error ELSE excluded.last_error END,
                 last_error_at = COALESCE(excluded.last_error_at, last_error_at),
                 last_duration_ms = excluded.last_duration_ms,
                 max_duration_ms = MAX(max_duration_ms, excluded.max_duration_ms),
                 last_fuel_used = excluded.last_fuel_used,
                 max_fuel_used = MAX(max_fuel_used, excluded.max_fuel_used)",
            module_id,
            command,
            failed,
            at,
            ok_at,
            failing_since,
            error,
            error_at,
            duration_ms,
            duration_ms,
            fuel_used,
            max_fuel
        )
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// Every module's recorded commands, grouped by module id.
    pub async fn module_run_stats(&self) -> anyhow::Result<HashMap<String, Vec<ModuleRunStat>>> {
        let rows = sqlx::query!(
            r#"SELECT module_id AS "module_id!", command AS "command!", run_count AS "run_count!",
                      failure_count AS "failure_count!", last_run_at AS "last_run_at!",
                      last_ok_at, failing_since, last_error, last_error_at,
                      last_duration_ms AS "last_duration_ms!", max_duration_ms AS "max_duration_ms!",
                      last_fuel_used, max_fuel_used AS "max_fuel_used!"
               FROM module_run_stats ORDER BY module_id, command"#
        )
        .fetch_all(&self.pool)
        .await?;
        let mut grouped: HashMap<String, Vec<ModuleRunStat>> = HashMap::new();
        for r in rows {
            grouped.entry(r.module_id).or_default().push(ModuleRunStat {
                command: r.command,
                run_count: r.run_count,
                failure_count: r.failure_count,
                last_run_at: r.last_run_at,
                last_ok_at: r.last_ok_at,
                failing_since: r.failing_since,
                last_error: r.last_error,
                last_error_at: r.last_error_at,
                last_duration_ms: r.last_duration_ms,
                max_duration_ms: r.max_duration_ms,
                last_fuel_used: r.last_fuel_used,
                max_fuel_used: r.max_fuel_used,
            });
        }
        Ok(grouped)
    }

    /// Entries and bytes (keys plus values) each module's `kv.store` holds.
    pub async fn module_storage_usage(&self) -> anyhow::Result<HashMap<String, StorageUsage>> {
        let rows = sqlx::query!(
            r#"SELECT module_id AS "module_id!", COUNT(*) AS "entries!: i64",
                      COALESCE(SUM(length(CAST(key AS BLOB)) + length(CAST(value AS BLOB))), 0) AS "bytes!: i64"
               FROM module_kv GROUP BY module_id"#
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .into_iter()
            .map(|r| {
                (
                    r.module_id,
                    StorageUsage {
                        entries: r.entries,
                        bytes: r.bytes,
                    },
                )
            })
            .collect())
    }

    /// Empties a module's `kv.store`, leaving it installed and approved.
    /// `Ok(None)` if the module is not installed.
    pub async fn clear_module_storage(&self, module_id: &str) -> anyhow::Result<Option<u64>> {
        let mut tx = self.begin_write().await?;
        let installed = sqlx::query_scalar!(
            r#"SELECT 1 AS "one!: i64" FROM installed_modules WHERE id = ?"#,
            module_id
        )
        .fetch_optional(&mut *tx)
        .await?;
        if installed.is_none() {
            return Ok(None);
        }
        let removed = sqlx::query!("DELETE FROM module_kv WHERE module_id = ?", module_id)
            .execute(&mut *tx)
            .await?
            .rows_affected();
        tx.commit().await?;
        Ok(Some(removed))
    }
}
