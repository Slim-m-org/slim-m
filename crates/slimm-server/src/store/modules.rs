// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Installed-module persistence: install (metadata plus the permissions it
//! declares), enable/disable, list, and uninstall. See `module_artifacts`
//! for the module's own wasm bytes and `crate::module_runtime` for the Phase
//! 3 host that runs them; see
//! docs/decisions/0021-modules-and-the-dock.md for the phasing this belongs
//! to.
//!
//! `runtime_limits` and `extension_points` are recorded here, at install
//! time, from the manifest the Dock just fetched and validated: the runtime
//! never re-fetches a manifest on every command call, so anything it needs
//! (a command's required permission key, the resource caps to run under) has
//! to be persisted alongside the rest of the install row.

use super::module_artifacts::store_module_artifact_tx;
use super::{Store, now_ms};

/// One installed module, as recorded at its last install.
#[derive(Debug, Clone)]
pub struct InstalledModule {
    pub id: String,
    pub name: String,
    pub version: String,
    pub artifact_sha256: String,
    pub approved_capabilities: Vec<String>,
    /// The subset of `approved_capabilities` an admin explicitly approved for
    /// the module to exercise through `slim.host_call` (decision 0023). Empty
    /// for every module installed before that approval existed.
    pub approved_host_capabilities: Vec<String>,
    pub runtime_limits: ModuleRuntimeLimits,
    pub extension_points: Vec<ModuleExtensionPoint>,
    pub enabled: bool,
    pub installed_at: i64,
    /// The `owner/repo` of the community source it was installed from, or
    /// `None` for the official one (decision 0046).
    pub source_repo: Option<String>,
}

/// The manifest's `runtime.limits`, persisted verbatim so the module host can
/// enforce them without a network round trip. Any field left unset by the
/// manifest falls back to the host's own default, applied where the limits
/// are read rather than here, so an installed row always reflects exactly
/// what the manifest declared.
#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
pub struct ModuleRuntimeLimits {
    pub memory_mb: Option<u64>,
    pub wall_ms: Option<u64>,
    pub fuel: Option<u64>,
}

/// One of the module's declared extension points, as recorded at install.
/// `permission` is the declared permission key (namespaced by this module's
/// id once granted, see `store::module_permissions`) a caller must hold to
/// reach it; a `command` extension point always carries one, checked by
/// `http::dock::manifest`'s own validation before this ever gets here.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct ModuleExtensionPoint {
    pub kind: String,
    pub name: String,
    pub description: Option<String>,
    pub permission: Option<String>,
    /// For a `code-block-runner`: the `command` extension point's own name
    /// it invokes. See `http::dock::manifest`'s own validation of this.
    pub command: Option<String>,
    /// For a `code-block-runner`: the fenced-block language it matches, or
    /// `None` for a wildcard that matches any block. `#[serde(default)]`
    /// so a module installed before this field existed still deserializes.
    #[serde(default)]
    pub language: Option<String>,
}

/// One permission a module's manifest declares, as install registers it into
/// `module_permissions`.
pub struct ModulePermissionSpec<'a> {
    pub key: &'a str,
    pub name: &'a str,
    pub description: &'a str,
}

/// One extension point a module's manifest declares, as install records it
/// onto the `installed_modules` row.
pub struct ModuleExtensionPointSpec<'a> {
    pub kind: &'a str,
    pub name: &'a str,
    pub description: Option<&'a str>,
    pub permission: Option<&'a str>,
    pub command: Option<&'a str>,
    pub language: Option<&'a str>,
}

/// Everything an install call needs, bundled so `Store::install_module_with_artifact` stays
/// under the project's 7-positional-parameter limit.
pub struct InstallModuleRequest<'a> {
    pub id: &'a str,
    pub name: &'a str,
    pub version: &'a str,
    pub artifact_sha256: &'a str,
    pub approved_capabilities: &'a [String],
    pub runtime_limits: &'a ModuleRuntimeLimits,
    pub permissions: &'a [ModulePermissionSpec<'a>],
    pub extension_points: &'a [ModuleExtensionPointSpec<'a>],
}

/// What the dock records alongside an install, in the same transaction as it.
pub struct DockProvenance<'a> {
    pub host_capabilities: &'a [String],
    /// The community source's slug; `None` is the official one.
    pub source_repo: Option<&'a str>,
}

struct ModuleRow {
    id: String,
    name: String,
    version: String,
    artifact_sha256: String,
    approved_capabilities: String,
    approved_host_capabilities: String,
    runtime_limits: String,
    extension_points: String,
    enabled: bool,
    installed_at: i64,
    source_repo: Option<String>,
}

impl From<ModuleRow> for InstalledModule {
    fn from(row: ModuleRow) -> Self {
        // A parse failure means the row was corrupted elsewhere; fall back to empty rather than erroring a read.
        let approved_capabilities =
            serde_json::from_str(&row.approved_capabilities).unwrap_or_default();
        let approved_host_capabilities =
            serde_json::from_str(&row.approved_host_capabilities).unwrap_or_default();
        let runtime_limits = serde_json::from_str(&row.runtime_limits).unwrap_or_default();
        let extension_points = serde_json::from_str(&row.extension_points).unwrap_or_default();
        Self {
            id: row.id,
            name: row.name,
            version: row.version,
            artifact_sha256: row.artifact_sha256,
            approved_capabilities,
            approved_host_capabilities,
            runtime_limits,
            extension_points,
            enabled: row.enabled,
            installed_at: row.installed_at,
            source_repo: row.source_repo,
        }
    }
}

impl Store {
    /// Installs (or reinstalls, at a possibly new version) a module.
    ///
    /// Idempotent by `id`: an existing row's metadata is overwritten with
    /// the freshly fetched manifest's, and `enabled` is left untouched by
    /// the `ON CONFLICT` clause - a reinstall must never silently flip a
    /// module back on. `module_permissions` is reconciled rather than
    /// replaced wholesale: a permission key the new manifest still declares
    /// keeps its row (and so keeps every role grant on it, which cascades
    /// away only when the row itself is deleted), while one the manifest
    /// dropped is deleted, cascading its grants with it. Delete-then-reinsert
    /// for every key would cascade away every grant on every reinstall, even
    /// when nothing about that permission changed.
    ///
    /// The metadata and the verified artifact bytes commit as one atomic
    /// write. Recording the two as separate writes let a racing upgrade, or a crash
    /// between them, leave `installed_modules` and `module_artifacts`
    /// describing different versions with no error anywhere. This method is the
    /// fix for that half of the defect;
    /// `http::module_commands::execute_command`'s comparison of
    /// `installed_modules.artifact_sha256` against the stored artifact's own
    /// sha is the other half, and is what makes a mismatch here actually
    /// unreachable rather than merely rarer.
    ///
    /// `artifact` must already be sha256-verified against
    /// `req.artifact_sha256` by the caller. The metadata row is written
    /// before the artifact row: `module_artifacts.module_id` is a foreign key
    /// onto `installed_modules(id)`, so the reverse order would violate it.
    pub async fn install_module_with_artifact(
        &self,
        req: InstallModuleRequest<'_>,
        artifact: &[u8],
    ) -> anyhow::Result<InstalledModule> {
        let mut tx = self.begin_write().await?;
        insert_module_metadata(&mut tx, &req).await?;
        store_module_artifact_tx(&mut tx, req.id, req.artifact_sha256, artifact).await?;
        tx.commit().await?;
        self.installed_module(req.id)
            .await?
            .ok_or_else(|| anyhow::anyhow!("install of {} did not persist", req.id))
    }

    /// [`Self::install_module_with_artifact`] plus the dock's own provenance,
    /// all in one transaction: the host capabilities the admin approved and the
    /// community source it came from. Written separately, a failure between the
    /// calls left a community module installed and reading as official.
    pub async fn install_module_from_dock(
        &self,
        req: InstallModuleRequest<'_>,
        artifact: &[u8],
        provenance: &DockProvenance<'_>,
    ) -> anyhow::Result<InstalledModule> {
        let mut tx = self.begin_write().await?;
        insert_module_metadata(&mut tx, &req).await?;
        store_module_artifact_tx(&mut tx, req.id, req.artifact_sha256, artifact).await?;
        let host_json = serde_json::to_string(provenance.host_capabilities)?;
        sqlx::query!(
            "UPDATE installed_modules SET approved_host_capabilities = ? WHERE id = ?",
            host_json,
            req.id
        )
        .execute(&mut *tx)
        .await?;
        sqlx::query!(
            "UPDATE installed_modules SET source_repo = ? WHERE id = ?",
            provenance.source_repo,
            req.id
        )
        .execute(&mut *tx)
        .await?;
        tx.commit().await?;
        self.installed_module(req.id)
            .await?
            .ok_or_else(|| anyhow::anyhow!("install of {} did not persist", req.id))
    }

    /// One installed module, or `None` if it is not (or no longer) installed.
    pub async fn installed_module(&self, id: &str) -> anyhow::Result<Option<InstalledModule>> {
        let row = sqlx::query_as!(
            ModuleRow,
            r#"SELECT id AS "id!", name AS "name!", version AS "version!",
                      artifact_sha256 AS "artifact_sha256!",
                      approved_capabilities AS "approved_capabilities!",
                      approved_host_capabilities AS "approved_host_capabilities!",
                      runtime_limits AS "runtime_limits!",
                      extension_points AS "extension_points!",
                      enabled AS "enabled!: bool", installed_at AS "installed_at!",
                      source_repo
               FROM installed_modules WHERE id = ?"#,
            id
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.map(InstalledModule::from))
    }

    /// Every installed module, most recently installed first.
    pub async fn list_installed_modules(&self) -> anyhow::Result<Vec<InstalledModule>> {
        let rows = sqlx::query_as!(
            ModuleRow,
            r#"SELECT id AS "id!", name AS "name!", version AS "version!",
                      artifact_sha256 AS "artifact_sha256!",
                      approved_capabilities AS "approved_capabilities!",
                      approved_host_capabilities AS "approved_host_capabilities!",
                      runtime_limits AS "runtime_limits!",
                      extension_points AS "extension_points!",
                      enabled AS "enabled!: bool", installed_at AS "installed_at!",
                      source_repo
               FROM installed_modules ORDER BY installed_at DESC"#
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows.into_iter().map(InstalledModule::from).collect())
    }

    /// Enables or disables an installed module. `Ok(false)` if it is not
    /// installed, so the caller can 404 rather than silently no-op.
    pub async fn set_module_enabled(&self, id: &str, enabled: bool) -> anyhow::Result<bool> {
        let enabled_bit = i64::from(enabled);
        let affected = sqlx::query!(
            "UPDATE installed_modules SET enabled = ? WHERE id = ?",
            enabled_bit,
            id
        )
        .execute(&self.pool)
        .await?
        .rows_affected();
        Ok(affected > 0)
    }

    /// Records which of a module's declared capabilities an admin approved for
    /// `slim.host_call`, replacing any earlier approval. `Ok(false)` if it is
    /// not installed. An upsert leaves the approval alone; `http::dock` decides
    /// per install whether to replace it or carry it forward.
    pub async fn set_module_host_capabilities(
        &self,
        id: &str,
        approved: &[String],
    ) -> anyhow::Result<bool> {
        let json = serde_json::to_string(approved)?;
        let affected = sqlx::query!(
            "UPDATE installed_modules SET approved_host_capabilities = ? WHERE id = ?",
            json,
            id
        )
        .execute(&self.pool)
        .await?
        .rows_affected();
        Ok(affected > 0)
    }

    /// Uninstalls a module. `Ok(false)` if it was not installed. The
    /// `module_permissions`, `role_module_permissions`, `module_artifacts` and
    /// `module_kv` rows all cascade away on the `installed_modules` foreign key, so
    /// nothing dangles: see the migrations' own comments.
    pub async fn uninstall_module(&self, id: &str) -> anyhow::Result<bool> {
        let affected = sqlx::query!("DELETE FROM installed_modules WHERE id = ?", id)
            .execute(&self.pool)
            .await?
            .rows_affected();
        Ok(affected > 0)
    }
}

/// The metadata half of an install: the `installed_modules` row itself, plus
/// the `module_permissions` reconciliation [`Store::install_module_with_artifact`]'s own
/// doc explains. Split out so [`Store::install_module_with_artifact`] and
/// [`Store::install_module_with_artifact`] run exactly the same metadata
/// write inside whichever transaction the caller owns, rather than drifting
/// into two copies of it.
pub(super) async fn insert_module_metadata(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    req: &InstallModuleRequest<'_>,
) -> anyhow::Result<()> {
    let now = now_ms();
    let caps_json = serde_json::to_string(req.approved_capabilities)?;
    let limits_json = serde_json::to_string(req.runtime_limits)?;
    let extension_points: Vec<ModuleExtensionPoint> = req
        .extension_points
        .iter()
        .map(|e| ModuleExtensionPoint {
            kind: e.kind.to_owned(),
            name: e.name.to_owned(),
            description: e.description.map(str::to_owned),
            permission: e.permission.map(str::to_owned),
            command: e.command.map(str::to_owned),
            language: e.language.map(str::to_owned),
        })
        .collect();
    let extension_points_json = serde_json::to_string(&extension_points)?;

    sqlx::query!(
        "INSERT INTO installed_modules
             (id, name, version, artifact_sha256, approved_capabilities,
              runtime_limits, extension_points, enabled, installed_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?)
         ON CONFLICT(id) DO UPDATE SET
             name = excluded.name,
             version = excluded.version,
             artifact_sha256 = excluded.artifact_sha256,
             approved_capabilities = excluded.approved_capabilities,
             runtime_limits = excluded.runtime_limits,
             extension_points = excluded.extension_points",
        req.id,
        req.name,
        req.version,
        req.artifact_sha256,
        caps_json,
        limits_json,
        extension_points_json,
        now
    )
    .execute(&mut **tx)
    .await?;

    let existing_keys: Vec<String> = sqlx::query_scalar!(
        "SELECT perm_key FROM module_permissions WHERE module_id = ?",
        req.id
    )
    .fetch_all(&mut **tx)
    .await?;
    for key in existing_keys {
        if !req.permissions.iter().any(|p| p.key == key) {
            sqlx::query!(
                "DELETE FROM module_permissions WHERE module_id = ? AND perm_key = ?",
                req.id,
                key
            )
            .execute(&mut **tx)
            .await?;
        }
    }
    for perm in req.permissions {
        sqlx::query!(
            "INSERT INTO module_permissions (module_id, perm_key, name, description)
             VALUES (?, ?, ?, ?)
             ON CONFLICT(module_id, perm_key) DO UPDATE SET
                 name = excluded.name, description = excluded.description",
            req.id,
            perm.key,
            perm.name,
            perm.description
        )
        .execute(&mut **tx)
        .await?;
    }
    Ok(())
}
