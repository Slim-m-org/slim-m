// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Durable storage behind a module's `kv.store` capability (decision 0023).
//! Rows are keyed by module id, and the foreign key to `installed_modules`
//! cascades, so uninstalling a module wipes its data.

use super::Store;

/// Why a `kv.store` write was refused by the store.
#[derive(Debug)]
pub enum KvSetError {
    /// The write would take the module past its entry or byte cap.
    Full,
    Internal(anyhow::Error),
}

impl From<sqlx::Error> for KvSetError {
    fn from(err: sqlx::Error) -> Self {
        KvSetError::Internal(err.into())
    }
}

impl Store {
    pub async fn module_kv_get(
        &self,
        module_id: &str,
        key: &str,
    ) -> anyhow::Result<Option<String>> {
        Ok(sqlx::query_scalar!(
            "SELECT value FROM module_kv WHERE module_id = ? AND key = ?",
            module_id,
            key
        )
        .fetch_optional(&self.pool)
        .await?)
    }

    /// Stores `value` at `key` unless it would take the module past
    /// `max_entries` or `max_bytes` (keys plus values, in bytes). The count and
    /// the write share one `BEGIN IMMEDIATE` transaction, so two concurrent
    /// runs cannot both squeeze under the cap.
    pub async fn module_kv_set(
        &self,
        module_id: &str,
        key: &str,
        value: &str,
        max_entries: i64,
        max_bytes: i64,
    ) -> Result<(), KvSetError> {
        let mut tx = self.begin_write().await?;
        let usage = sqlx::query!(
            r#"SELECT COUNT(*) AS "entries!: i64",
                      COALESCE(SUM(length(CAST(key AS BLOB)) + length(CAST(value AS BLOB))), 0) AS "bytes!: i64"
               FROM module_kv WHERE module_id = ? AND key <> ?"#,
            module_id,
            key
        )
        .fetch_one(&mut *tx)
        .await?;
        let new_bytes = (key.len() + value.len()) as i64;
        if usage.entries + 1 > max_entries || usage.bytes + new_bytes > max_bytes {
            return Err(KvSetError::Full);
        }
        sqlx::query!(
            "INSERT INTO module_kv (module_id, key, value) VALUES (?, ?, ?)
             ON CONFLICT(module_id, key) DO UPDATE SET value = excluded.value",
            module_id,
            key,
            value
        )
        .execute(&mut *tx)
        .await?;
        tx.commit().await?;
        Ok(())
    }

    pub async fn module_kv_delete(&self, module_id: &str, key: &str) -> anyhow::Result<()> {
        sqlx::query!(
            "DELETE FROM module_kv WHERE module_id = ? AND key = ?",
            module_id,
            key
        )
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn module_kv_keys(&self, module_id: &str, limit: i64) -> anyhow::Result<Vec<String>> {
        Ok(sqlx::query_scalar!(
            "SELECT key FROM module_kv WHERE module_id = ? ORDER BY key LIMIT ?",
            module_id,
            limit
        )
        .fetch_all(&self.pool)
        .await?)
    }
}
