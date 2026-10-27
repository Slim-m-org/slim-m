// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The metadata half of a module install, shared by both install paths.

use super::{InstallModuleRequest, ModuleExtensionPoint};
use crate::store::now_ms;

/// The metadata half of an install: the `installed_modules` row itself, plus
/// the `module_permissions` reconciliation [`Store::install_module_with_artifact`]'s own
/// doc explains. Split out so [`Store::install_module_with_artifact`] and
/// [`Store::install_module_with_artifact`] run exactly the same metadata
/// write inside whichever transaction the caller owns, rather than drifting
/// into two copies of it.
pub(in crate::store) async fn insert_module_metadata(
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
    prune_undeclared_run_stats(tx, req).await?;
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

/// Drops run history for commands the installed build no longer declares, keeping the host's own keys.
async fn prune_undeclared_run_stats(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    req: &InstallModuleRequest<'_>,
) -> anyhow::Result<()> {
    let recorded: Vec<String> = sqlx::query_scalar!(
        "SELECT command FROM module_run_stats WHERE module_id = ?",
        req.id
    )
    .fetch_all(&mut **tx)
    .await?;
    for command in recorded {
        // Host-run keys such as "@event" and "@slot" are not commands a manifest declares.
        let declared = command.starts_with('@')
            || req
                .extension_points
                .iter()
                .any(|e| e.kind == "command" && e.name == command);
        if !declared {
            sqlx::query!(
                "DELETE FROM module_run_stats WHERE module_id = ? AND command = ?",
                req.id,
                command
            )
            .execute(&mut **tx)
            .await?;
        }
    }
    Ok(())
}
