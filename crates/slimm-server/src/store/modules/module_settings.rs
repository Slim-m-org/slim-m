// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Stored setting values for an installed module (decision 0091). A value is
//! its JSON text; the definitions live on the `installed_modules` row.

use std::collections::BTreeMap;

use serde_json::Value;

use super::platform::{ModuleSettingDef, SettingKind};
use crate::store::{Store, now_ms};

impl Store {
    /// Every stored value for `module_id`, keyed by setting key.
    pub async fn module_setting_values(
        &self,
        module_id: &str,
    ) -> anyhow::Result<BTreeMap<String, Value>> {
        let rows = sqlx::query!(
            "SELECT key, value FROM module_settings WHERE module_id = ?",
            module_id
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .into_iter()
            .filter_map(|r| Some((r.key, serde_json::from_str(&r.value).ok()?)))
            .collect())
    }

    /// One stored value, or `None` when unset.
    pub async fn module_setting_value(
        &self,
        module_id: &str,
        key: &str,
    ) -> anyhow::Result<Option<Value>> {
        let text = sqlx::query_scalar!(
            "SELECT value AS \"value!: String\" FROM module_settings WHERE module_id = ? AND key = ?",
            module_id,
            key
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(text.and_then(|t| serde_json::from_str(&t).ok()))
    }

    /// Applies already-validated changes in one transaction: `Some` sets, `None` clears.
    pub async fn apply_module_settings(
        &self,
        module_id: &str,
        changes: &[(String, Option<Value>)],
    ) -> anyhow::Result<()> {
        let now = now_ms();
        let mut tx = self.begin_write().await?;
        for (key, value) in changes {
            match value {
                Some(value) => {
                    let text = serde_json::to_string(value)?;
                    sqlx::query!(
                        "INSERT INTO module_settings (module_id, key, value, updated_at)
                         VALUES (?, ?, ?, ?)
                         ON CONFLICT(module_id, key) DO UPDATE SET
                             value = excluded.value, updated_at = excluded.updated_at",
                        module_id,
                        key,
                        text,
                        now
                    )
                    .execute(&mut *tx)
                    .await?;
                }
                None => {
                    sqlx::query!(
                        "DELETE FROM module_settings WHERE module_id = ? AND key = ?",
                        module_id,
                        key
                    )
                    .execute(&mut *tx)
                    .await?;
                }
            }
        }
        tx.commit().await?;
        Ok(())
    }

    /// What a run hands the module: stored values over defaults, secrets left out.
    pub async fn module_run_settings(
        &self,
        module_id: &str,
        defs: &[ModuleSettingDef],
    ) -> anyhow::Result<BTreeMap<String, Value>> {
        if defs.is_empty() {
            return Ok(BTreeMap::new());
        }
        let stored = self.module_setting_values(module_id).await?;
        let mut out = BTreeMap::new();
        for def in defs.iter().filter(|d| d.kind != SettingKind::Secret) {
            let value = stored.get(&def.key).or(def.default.as_ref());
            if let Some(value) = value {
                out.insert(def.key.clone(), value.clone());
            }
        }
        Ok(out)
    }
}
