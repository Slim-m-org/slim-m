// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Running an installed module once it is gated: the wire request it reads,
//! the response it returns, and the artifact check before it runs. Shared by
//! commands people invoke (`super::module_commands`) and scheduled runs
//! (`super::module_schedule`).

use std::collections::BTreeMap;
use std::time::Instant;

use rand_core::{OsRng, RngCore};
use serde::{Deserialize, Serialize};

use super::AppState;
use super::error::ApiError;
use super::module_commands::CommandOutcome;
use super::module_host::effective_capabilities;
use crate::ids::UserId;
use crate::module_runtime::{CapabilitySurface, ModuleHost, RunError, RunLane, RunLimits};
use crate::store::{InstalledModule, RunResult, RunTiming, now_ms};

#[derive(Serialize)]
struct ModuleWireRequest<'a> {
    command: &'a str,
    input: &'a str,
    caller: ModuleCaller,
    entropy: String,
    /// The host's wall clock, UTC epoch milliseconds: a module has no clock of its own.
    now_ms: i64,
    /// The admin's values over the manifest's defaults, left out when empty; secrets are never here.
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    settings: BTreeMap<String, serde_json::Value>,
}

/// 16 fresh random bytes as hex, new for every run. A module has no random
/// source, so this is the only thing a roll can vary with. See
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

/// Who started a run, which decides its lane and how it is held to account.
#[derive(Clone, Copy, PartialEq, Eq)]
pub(crate) enum RunKind {
    /// A member invoked a command and waits for the answer.
    Command,
    /// The host started it (schedule or pushed event): it draws on the
    /// background lane, `ok:false` counts as failed, and the circuit breaker watches it.
    Background,
    /// A slot fill: its own lane, `ok:false` counts as failed in the stats,
    /// but a member viewing profiles can never trip the breaker.
    Slot,
}

/// One gated run: who asked, for which command, and what started it.
pub(crate) struct RunRequest<'a> {
    pub(crate) caller: UserId,
    pub(crate) command: &'a str,
    pub(crate) input: &'a str,
    pub(crate) kind: RunKind,
}

/// Runs an already-gated command on `module`, with `surface` as its
/// capabilities, and records how it went. Shared by invoked runs and
/// scheduled ones.
pub(crate) async fn run_installed(
    state: &AppState,
    module: &InstalledModule,
    request: &RunRequest<'_>,
    surface: CapabilitySurface,
) -> Result<CommandOutcome, ApiError> {
    let started = Instant::now();
    let (ran, fuel_used) = run_checked(state, module, request, surface).await;
    if request.kind == RunKind::Slot
        && ran
            .as_ref()
            .is_ok_and(super::module_breaker::was_turned_away)
    {
        return ran;
    }
    let result = match &ran {
        Ok(outcome) if outcome.host_failed || (!outcome.ok && request.kind != RunKind::Command) => {
            RunResult::Failed(outcome.payload.clone())
        }
        Ok(_) => RunResult::Ok,
        Err(_) => {
            RunResult::Failed("the module could not be started; reinstall it from the Dock".into())
        }
    };
    let duration_ms = i64::try_from(started.elapsed().as_millis()).unwrap_or(i64::MAX);
    if let Err(err) = state
        .store
        .record_module_run(
            &module.id,
            request.command,
            &result,
            RunTiming {
                at: now_ms(),
                duration_ms,
                fuel_used: fuel_used.and_then(|fuel| i64::try_from(fuel).ok()),
            },
        )
        .await
    {
        tracing::warn!(%err, module = %module.id, "could not record a module run");
    }
    if request.kind == RunKind::Background {
        super::module_breaker::note_background_run(state, module, &result, ran.as_ref().ok()).await;
    }
    ran
}

/// The run and the fuel it burned, when that could be read.
async fn run_checked(
    state: &AppState,
    module: &InstalledModule,
    request: &RunRequest<'_>,
    surface: CapabilitySurface,
) -> (Result<CommandOutcome, ApiError>, Option<u64>) {
    match prepare_and_run(state, module, request, surface).await {
        Ok((outcome, fuel)) => (Ok(outcome), fuel),
        Err(err) => (Err(err), None),
    }
}

async fn prepare_and_run(
    state: &AppState,
    module: &InstalledModule,
    request: &RunRequest<'_>,
    surface: CapabilitySurface,
) -> Result<(CommandOutcome, Option<u64>), ApiError> {
    let module_id = module.id.as_str();
    let Some(stored_sha256) = state.store.module_artifact_sha256(module_id).await? else {
        return Err(ApiError::Conflict(
            "module has no stored artifact; reinstall it from the Dock",
        ));
    };
    if stored_sha256 != module.artifact_sha256 {
        return Err(ApiError::Conflict(
            "module's stored artifact does not match its approved version; reinstall it from the Dock",
        ));
    }
    let mut limits = RunLimits::from(&module.runtime_limits);
    if effective_capabilities(module)
        .iter()
        .any(|c| c == "net.fetch")
    {
        limits = limits.for_fetching();
    }
    let settings = state
        .store
        .module_run_settings(module_id, &module.settings_schema)
        .await?;
    let caller_key = state.store.module_caller_key().await?;
    let request_json = serde_json::to_vec(&ModuleWireRequest {
        command: request.command,
        input: request.input,
        caller: ModuleCaller {
            id: super::module_caller::module_caller_id(&caller_key, module_id, request.caller),
        },
        entropy: run_entropy(),
        now_ms: now_ms(),
        settings,
    })
    .map_err(|_| ApiError::Internal)?;

    let store = state.store.clone();
    let lane = match request.kind {
        RunKind::Command => RunLane::Member,
        RunKind::Background => RunLane::Background,
        RunKind::Slot => RunLane::Slot,
    };
    let (ran, fuel) = ModuleHost::run_metered_in(
        lane,
        &module.artifact_sha256,
        (limits, request_json, surface),
        || async move {
            match store.module_artifact(module_id).await {
                Ok(Some((_, wasm))) => Ok(wasm),
                _ => Err(RunError::Instantiate(
                    "module artifact is unavailable".into(),
                )),
            }
        },
    )
    .await;
    let outcome = match ran {
        Ok(bytes) => interpret(&bytes),
        Err(err) => CommandOutcome::host_failure(describe(&err)),
    };
    Ok((outcome, fuel))
}

/// The module's own answer, or a host failure when it is not the ABI's shape.
fn interpret(bytes: &[u8]) -> CommandOutcome {
    match serde_json::from_slice::<ModuleWireResponse>(bytes) {
        Ok(wire) if wire.ok && wire.output.is_some() => CommandOutcome {
            ok: true,
            payload: wire.output.unwrap_or_default(),
            host_failed: false,
        },
        Ok(wire) if !wire.ok && wire.error.is_some() => CommandOutcome {
            ok: false,
            payload: wire.error.unwrap_or_default(),
            host_failed: false,
        },
        _ => CommandOutcome::host_failure("module returned a malformed response".to_string()),
    }
}

/// A message safe to hand back to the caller: every [`RunError`] variant is
/// already a clean, non-sensitive description (see its own `Display`), never
/// a stack trace or an internal type path.
fn describe(err: &RunError) -> String {
    err.to_string()
}
