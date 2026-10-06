// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A module's own wasm bytes, fetched and sha256-verified by `http::dock`'s
//! install handler and read back here by `crate::module_runtime`'s host on
//! every command call. See migration 0065 for why these live as a row rather
//! than a media-style file.

use super::{Store, now_ms};

impl Store {
    /// A module's stored artifact bytes and the sha256 they were recorded
    /// under, or `None` if none were ever stored (an install that predates
    /// this table, or one whose artifact fetch failed).
    pub async fn module_artifact(
        &self,
        module_id: &str,
    ) -> anyhow::Result<Option<(String, Vec<u8>)>> {
        let row = sqlx::query!(
            r#"SELECT sha256 AS "sha256!", bytes AS "bytes!" FROM module_artifacts WHERE module_id = ?"#,
            module_id
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.map(|r| (r.sha256, r.bytes)))
    }
}

/// Records (or replaces, on a reinstall) a module's artifact bytes inside a
/// transaction the caller owns, so the write commits or rolls back with
/// whatever else that transaction does - used by the install paths so an
/// install's metadata and its bytes can never diverge. `module_id` must
/// already exist in `installed_modules` within this same transaction, or the
/// foreign key fails.
pub(super) async fn store_module_artifact_tx(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    module_id: &str,
    sha256: &str,
    bytes: &[u8],
) -> anyhow::Result<()> {
    let now = now_ms();
    sqlx::query!(
        "INSERT INTO module_artifacts (module_id, sha256, bytes, stored_at)
         VALUES (?, ?, ?, ?)
         ON CONFLICT(module_id) DO UPDATE SET
             sha256 = excluded.sha256,
             bytes = excluded.bytes,
             stored_at = excluded.stored_at",
        module_id,
        sha256,
        bytes,
        now
    )
    .execute(&mut **tx)
    .await?;
    Ok(())
}
