// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `connector_host_runs` (migration 0211): what the host asks the supervisor to run for a
//! host-run connector (decision 0134). The token is never stored here.

use serde::{Deserialize, Serialize};

use crate::ids::UserId;
use crate::store::{Store, now_ms};

/// One approved `host:port` a connector's gateway may forward to.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EgressHost {
    pub host: String,
    pub port: u16,
}

/// What the admin approved for a host-run connector at install.
#[derive(Debug, Clone, PartialEq)]
pub struct HostRunSpec {
    pub image: String,
    pub egress: Vec<EgressHost>,
    pub egress_private: bool,
    pub volume: bool,
    pub memory_mib: Option<i64>,
    pub cpus: Option<f64>,
    pub pids: Option<i64>,
    pub volume_mib: Option<i64>,
}

/// A host-run connector as stored, with the module fields the runtime acts on.
#[derive(Debug, Clone, PartialEq)]
pub struct HostRun {
    pub module_id: String,
    pub run_id: String,
    pub spec: HostRunSpec,
    pub enabled: bool,
    pub principal: Option<UserId>,
    pub refused: bool,
    pub last_error: Option<String>,
    pub crash_disabled_at: Option<i64>,
}

struct Row {
    module_id: String,
    run_id: String,
    image: String,
    egress: String,
    egress_private: i64,
    volume: i64,
    memory_mib: Option<i64>,
    cpus: Option<f64>,
    pids: Option<i64>,
    volume_mib: Option<i64>,
    refused: i64,
    last_error: Option<String>,
    crash_disabled_at: Option<i64>,
    enabled: i64,
    bot_user_id: Option<UserId>,
}

impl From<Row> for HostRun {
    fn from(r: Row) -> Self {
        Self {
            module_id: r.module_id,
            run_id: r.run_id,
            spec: HostRunSpec {
                image: r.image,
                egress: serde_json::from_str(&r.egress).unwrap_or_default(),
                egress_private: r.egress_private != 0,
                volume: r.volume != 0,
                memory_mib: r.memory_mib,
                cpus: r.cpus,
                pids: r.pids,
                volume_mib: r.volume_mib,
            },
            enabled: r.enabled != 0,
            principal: r.bot_user_id,
            refused: r.refused != 0,
            last_error: r.last_error,
            crash_disabled_at: r.crash_disabled_at,
        }
    }
}

impl Store {
    /// Records the approved spec; a new row gets a fresh run id, an existing one keeps its id
    /// and has its refusal and crash marks cleared, since an update is a new consent.
    pub async fn upsert_host_run(
        &self,
        module_id: &str,
        spec: &HostRunSpec,
    ) -> anyhow::Result<HostRun> {
        let run_id = uuid::Uuid::now_v7().hyphenated().to_string();
        let egress = serde_json::to_string(&spec.egress)?;
        let now = now_ms();
        sqlx::query!(
            "INSERT INTO connector_host_runs
                 (module_id, run_id, image, egress, egress_private, volume, memory_mib, cpus, pids,
                  volume_mib, created_at)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
             ON CONFLICT(module_id) DO UPDATE SET
                 image = excluded.image, egress = excluded.egress,
                 egress_private = excluded.egress_private, volume = excluded.volume,
                 memory_mib = excluded.memory_mib, cpus = excluded.cpus, pids = excluded.pids,
                 volume_mib = excluded.volume_mib,
                 refused = 0, last_error = NULL, crash_disabled_at = NULL",
            module_id,
            run_id,
            spec.image,
            egress,
            spec.egress_private,
            spec.volume,
            spec.memory_mib,
            spec.cpus,
            spec.pids,
            spec.volume_mib,
            now
        )
        .execute(&self.pool)
        .await?;
        self.host_run(module_id)
            .await?
            .ok_or_else(|| anyhow::anyhow!("host run for {module_id} did not persist"))
    }

    pub async fn host_run(&self, module_id: &str) -> anyhow::Result<Option<HostRun>> {
        let row = sqlx::query_as!(
            Row,
            r#"SELECT h.module_id, h.run_id, h.image, h.egress, h.egress_private, h.volume,
                      h.memory_mib, h.cpus, h.pids, h.volume_mib, h.refused, h.last_error, h.crash_disabled_at,
                      m.enabled, m.bot_user_id AS "bot_user_id: UserId"
               FROM connector_host_runs h JOIN installed_modules m ON m.id = h.module_id
               WHERE h.module_id = ?"#,
            module_id
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.map(HostRun::from))
    }

    pub async fn host_runs(&self) -> anyhow::Result<Vec<HostRun>> {
        let rows = sqlx::query_as!(
            Row,
            r#"SELECT h.module_id, h.run_id, h.image, h.egress, h.egress_private, h.volume,
                      h.memory_mib, h.cpus, h.pids, h.volume_mib, h.refused, h.last_error, h.crash_disabled_at,
                      m.enabled, m.bot_user_id AS "bot_user_id: UserId"
               FROM connector_host_runs h JOIN installed_modules m ON m.id = h.module_id
               ORDER BY h.module_id"#
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows.into_iter().map(HostRun::from).collect())
    }

    /// The reason the admin sees; `refused` stops retries until the connector is enabled again.
    pub async fn set_host_run_error(
        &self,
        module_id: &str,
        error: Option<&str>,
        refused: bool,
    ) -> anyhow::Result<()> {
        sqlx::query!(
            "UPDATE connector_host_runs SET last_error = ?, refused = ? WHERE module_id = ?",
            error,
            refused,
            module_id
        )
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// Forgets the host-run row when an update makes the connector admin-started.
    pub async fn delete_host_run(&self, module_id: &str) -> anyhow::Result<()> {
        sqlx::query!(
            "DELETE FROM connector_host_runs WHERE module_id = ?",
            module_id
        )
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// Marks the connector turned off for crashing, or clears the mark and any refusal when
    /// an admin enables it again.
    pub async fn set_host_run_crash_disabled(
        &self,
        module_id: &str,
        at: Option<i64>,
    ) -> anyhow::Result<()> {
        sqlx::query!(
            "UPDATE connector_host_runs
             SET crash_disabled_at = ?,
                 refused = CASE WHEN ? IS NULL THEN 0 ELSE refused END,
                 last_error = CASE WHEN ? IS NULL THEN NULL ELSE last_error END
             WHERE module_id = ?",
            at,
            at,
            at,
            module_id
        )
        .execute(&self.pool)
        .await?;
        Ok(())
    }
}
