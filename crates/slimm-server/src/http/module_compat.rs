// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Keeping a module this server cannot speak to from ever running (decision
//! 0100): its declared add-on API range is checked at install, here at every
//! start, on enabling it, and before each run.

use super::AppState;
use super::error::ApiError;
use crate::module_runtime::check_compatible;
use crate::store::InstalledModule;

/// Why `module` cannot run on this server, or `None` when it can.
pub(crate) fn incompatibility(module: &InstalledModule) -> Option<String> {
    check_compatible(module.addon_api, module.addon_api_max).err()
}

/// Refuses with the reason when `module` is outside this server's add-on API.
pub(crate) fn require_compatible(module: &InstalledModule) -> Result<(), ApiError> {
    match incompatibility(module) {
        None => Ok(()),
        Some(reason) => Err(ApiError::ConflictDetail(reason)),
    }
}

/// Turns off every enabled module outside this server's range, with the reason the admin sees.
pub async fn disable_incompatible(state: &AppState) {
    let modules = match state.store.list_installed_modules().await {
        Ok(modules) => modules,
        Err(err) => {
            tracing::warn!(%err, "could not check installed modules against the add-on API");
            return;
        }
    };
    for module in modules.iter().filter(|m| m.enabled) {
        let Some(reason) = incompatibility(module) else {
            continue;
        };
        tracing::warn!(module = %module.id, %reason, "disabled a module outside the add-on API range");
        if let Err(err) = state
            .store
            .disable_module_incompatible(&module.id, &reason)
            .await
        {
            tracing::warn!(%err, module = %module.id, "could not disable an incompatible module");
        }
    }
}
