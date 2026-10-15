// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Running an installed module once it is gated: the wire request it reads,
//! the response it returns, and the artifact check before it runs. Shared by
//! commands people invoke (`super::module_commands`) and scheduled runs
//! (`super::module_schedule`).

use rand_core::{OsRng, RngCore};
use serde::{Deserialize, Serialize};

use super::AppState;
use super::error::ApiError;
use super::module_commands::CommandOutcome;
use crate::ids::UserId;
use crate::module_runtime::{CapabilitySurface, ModuleHost, RunError, RunLimits};
use crate::store::InstalledModule;

#[derive(Serialize)]
struct ModuleWireRequest<'a> {
    command: &'a str,
    input: &'a str,
    caller: ModuleCaller,
    entropy: String,
}

/// 16 fresh random bytes as hex, new for every run. A module has no clock or
/// random source, so this is the only thing a roll can vary with. See
/// docs/decisions/0038-module-caller-id.md, "Amended 2026-10-06".
fn run_entropy() -> String {
    let mut bytes = [0u8; 16];
    OsRng.fill_bytes(&mut bytes);
    crate::media::to_hex(&bytes)
}

/// Who is asking, and nothing more: an id a module can dedupe against.
/// See docs/decisions/0038-module-caller-id.md.
#[derive(Serialize)]
struct ModuleCaller {
    id: String,
}

#[derive(Deserialize)]
struct ModuleWireResponse {
    ok: bool,
    #[serde(default)]
    output: Option<String>,
    #[serde(default)]
    error: Option<String>,
}

/// Runs an already-gated `command` on `module` for `caller`, with `surface`
/// as its capabilities. Shared by invoked runs and scheduled ones.
pub(crate) async fn run_installed(
    state: &AppState,
    module: &InstalledModule,
    caller: UserId,
    command: &str,
    input: &str,
    surface: CapabilitySurface,
) -> Result<CommandOutcome, ApiError> {
    let module_id = module.id.as_str();
    let Some((stored_sha256, wasm)) = state.store.module_artifact(module_id).await? else {
        return Err(ApiError::Conflict(
            "module has no stored artifact; reinstall it from the Dock",
        ));
    };
    if stored_sha256 != module.artifact_sha256 {
        return Err(ApiError::Conflict(
            "module's stored artifact does not match its approved version; reinstall it from the Dock",
        ));
    }
    let limits = RunLimits::from(&module.runtime_limits);
    let caller_key = state.store.module_caller_key().await?;
    let request_json = serde_json::to_vec(&ModuleWireRequest {
        command,
        input,
        caller: ModuleCaller {
            id: super::module_caller::module_caller_id(&caller_key, module_id, caller),
        },
        entropy: run_entropy(),
    })
    .map_err(|_| ApiError::Internal)?;

    let ran = ModuleHost::run_with_capabilities(
        wasm,
        module.artifact_sha256.clone(),
        limits,
        request_json,
        surface,
    )
    .await;
    let outcome = match ran {
        Ok(bytes) => match serde_json::from_slice::<ModuleWireResponse>(&bytes) {
            Ok(wire) if wire.ok && wire.output.is_some() => CommandOutcome {
                ok: true,
                payload: wire.output.unwrap_or_default(),
            },
            Ok(wire) if !wire.ok && wire.error.is_some() => CommandOutcome {
                ok: false,
                payload: wire.error.unwrap_or_default(),
            },
            _ => CommandOutcome {
                ok: false,
                payload: "module returned a malformed response".to_string(),
            },
        },
        Err(err) => CommandOutcome {
            ok: false,
            payload: describe(&err),
        },
    };
    Ok(outcome)
}

/// A message safe to hand back to the caller: every [`RunError`] variant is
/// already a clean, non-sensitive description (see its own `Display`), never
/// a stack trace or an internal type path.
fn describe(err: &RunError) -> String {
    err.to_string()
}
