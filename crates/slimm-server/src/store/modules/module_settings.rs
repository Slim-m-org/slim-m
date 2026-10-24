// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Stored setting values for an installed module (decision 0091). A value is
//! its JSON text; the definitions live on the `installed_modules` row.

use std::collections::{BTreeMap, BTreeSet};

use serde_json::Value;

use super::platform::{ModuleSettingDef, SettingKind};
use crate::store::{Store, now_ms};

/// Version prefix of a sealed secret setting; a later key rotation gets its own.
const SEALED_SETTING: &str = "msec1:";

fn setting_context(module_id: &str, key: &str) -> String {
    format!("module-setting:{module_id}:{key}")
}

fn is_secret(defs: &[ModuleSettingDef], key: &str) -> bool {
    defs.iter()
        .any(|d| d.key == key && d.kind == SettingKind::Secret)
}

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
            .filter(|r| !r.value.starts_with(SEALED_SETTING))
            .filter_map(|r| Some((r.key, serde_json::from_str(&r.value).ok()?)))
            .collect())
    }

    /// Whether any module secret is sealed, so the data key must exist to open it.
    pub async fn has_sealed_module_secrets(&self) -> anyhow::Result<bool> {
        let found = sqlx::query_scalar!(
            r#"SELECT EXISTS(SELECT 1 FROM module_settings WHERE value LIKE 'msec1:%') AS "found!: bool""#
        )
        .fetch_one(&self.pool)
        .await?;
        Ok(found)
    }

    /// The keys that have a stored value, secrets included; never the values.
    pub async fn module_setting_keys_set(
        &self,
        module_id: &str,
    ) -> anyhow::Result<BTreeSet<String>> {
        let keys = sqlx::query_scalar!(
            "SELECT key FROM module_settings WHERE module_id = ?",
            module_id
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(keys.into_iter().collect())
    }

    /// The plaintext of a secret setting, or `None` when unset or it does not open. A value
    /// stored before sealing existed is sealed in place on this first use.
    pub async fn module_secret(&self, module_id: &str, key: &str) -> Option<String> {
        let stored = sqlx::query_scalar!(
            "SELECT value AS \"value!: String\" FROM module_settings WHERE module_id = ? AND key = ?",
            module_id,
            key
        )
        .fetch_optional(&self.pool)
        .await
        .ok()??;
        let context = setting_context(module_id, key);
        if stored.starts_with(SEALED_SETTING) {
            return self
                .data_key
                .open_prefixed(SEALED_SETTING, &context, &stored)
                .ok();
        }
        let plaintext = serde_json::from_str::<Value>(&stored)
            .ok()?
            .as_str()?
            .to_owned();
        self.seal_legacy_module_secret(module_id, key, &stored)
            .await;
        Some(plaintext)
    }

    /// Seals the plaintext `stored` in place, only while the row still holds exactly that,
    /// so an admin's newer value is never overwritten. Whether the row was sealed.
    pub async fn seal_legacy_module_secret(
        &self,
        module_id: &str,
        key: &str,
        stored: &str,
    ) -> bool {
        let context = setting_context(module_id, key);
        let Some(plaintext) = serde_json::from_str::<Value>(stored)
            .ok()
            .and_then(|v| v.as_str().map(str::to_owned))
        else {
            return false;
        };
        let Ok(sealed) = self
            .data_key
            .seal_prefixed(SEALED_SETTING, &context, &plaintext)
        else {
            return false;
        };
        sqlx::query!(
            "UPDATE module_settings SET value = ? WHERE module_id = ? AND key = ? AND value = ?",
            sealed,
            module_id,
            key,
            stored
        )
        .execute(&self.pool)
        .await
        .is_ok_and(|done| done.rows_affected() == 1)
    }

    /// Applies already-validated changes in one transaction: `Some` sets, `None` clears.
    pub async fn apply_module_settings(
        &self,
        module_id: &str,
        defs: &[ModuleSettingDef],
        changes: &[(String, Option<Value>)],
    ) -> anyhow::Result<()> {
        let now = now_ms();
        let mut tx = self.begin_write().await?;
        for (key, value) in changes {
            match value {
                Some(value) => {
                    let text = self.stored_form(module_id, defs, key, value)?;
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

    fn stored_form(
        &self,
        module_id: &str,
        defs: &[ModuleSettingDef],
        key: &str,
        value: &Value,
    ) -> anyhow::Result<String> {
        let Some(plaintext) = value.as_str().filter(|_| is_secret(defs, key)) else {
            return Ok(serde_json::to_string(value)?);
        };
        let context = setting_context(module_id, key);
        self.data_key
            .seal_prefixed(SEALED_SETTING, &context, plaintext)
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
