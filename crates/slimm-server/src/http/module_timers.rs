// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! One-shot timers a module sets from its own answer (`"run_after"`, docs/
//! modules/building-modules.md): the host runs one of the module's commands
//! once, no sooner than [`MIN_DELAY_MS`] later, as the module's own principal.
//! Schedules answer "every N minutes"; this answers "at the end of this
//! phase". It needs the same approved `schedule` capability.

use std::time::Duration;

use serde::Deserialize;
use serde_json::Value;

use super::AppState;
use super::module_host::{background_surface, schedule_approved};
use super::module_run::{RunContext, RunKind, RunRequest, run_installed};
use crate::store::{InstalledModule, TimerSpec, now_ms};

/// A timer fires no sooner than this after it was asked for, whatever the module wrote.
pub(crate) const MIN_DELAY_MS: i64 = 10_000;
const MAX_DELAY_MS: i64 = 7 * 24 * 60 * 60_000;
const MAX_PENDING: i64 = 32;
const MAX_KEY_BYTES: usize = 64;
const MAX_INPUT_BYTES: usize = 4096;
const SWEEP_EVERY: Duration = Duration::from_secs(5);
const BATCH: i64 = 16;

#[derive(Deserialize)]
struct RunAfter {
    command: String,
    #[serde(default)]
    after_ms: Option<i64>,
    #[serde(default)]
    key: String,
    #[serde(default)]
    input: String,
    #[serde(default)]
    cancel: bool,
}

/// Acts on the `run_after` in an answer the module just gave. Anything the
/// host will not honour is dropped with a log line: the answer itself stands.
pub(super) async fn apply(
    state: &AppState,
    module: &InstalledModule,
    context: RunContext,
    answer: &[u8],
) {
    if !String::from_utf8_lossy(answer).contains("\"run_after\"") {
        return;
    }
    let Ok(Value::Object(mut wire)) = serde_json::from_slice::<Value>(answer) else {
        return;
    };
    if wire.get("ok") != Some(&Value::Bool(true)) {
        return;
    }
    let Some(asked) = wire
        .remove("run_after")
        .and_then(|v| serde_json::from_value::<RunAfter>(v).ok())
    else {
        return;
    };
    if let Some(reason) = refusal(module, &asked) {
        tracing::info!(module = %module.id, reason, "module timer refused");
        return;
    }
    let outcome = if asked.cancel {
        state
            .store
            .cancel_module_timer(&module.id, &asked.command, &asked.key)
            .await
            .map(|_| true)
    } else {
        let delay = asked
            .after_ms
            .unwrap_or(0)
            .clamp(MIN_DELAY_MS, MAX_DELAY_MS);
        let timer = TimerSpec {
            command: &asked.command,
            key: &asked.key,
            input: &asked.input,
            channel_id: context.channel,
            run_at: now_ms() + delay,
        };
        state
            .store
            .set_module_timer(&module.id, &timer, MAX_PENDING)
            .await
    };
    match outcome {
        Ok(true) => {}
        Ok(false) => tracing::info!(module = %module.id, "module timer refused: too many pending"),
        Err(err) => tracing::warn!(%err, module = %module.id, "could not store a module timer"),
    }
}

fn refusal(module: &InstalledModule, asked: &RunAfter) -> Option<&'static str> {
    if module.bot_user_id.is_none() || !schedule_approved(module) {
        return Some("the schedule capability is not approved");
    }
    if !declares_command(module, &asked.command) {
        return Some("the module declares no such command");
    }
    if asked.key.len() > MAX_KEY_BYTES || asked.input.len() > MAX_INPUT_BYTES {
        return Some("the key or input is too long");
    }
    None
}

fn declares_command(module: &InstalledModule, command: &str) -> bool {
    module
        .extension_points
        .iter()
        .any(|e| e.kind == "command" && e.name == command)
}

pub(crate) fn spawn_sweep(state: AppState) {
    crate::sweeps::spawn_sweep(SWEEP_EVERY, move || {
        let state = state.clone();
        async move {
            match run_due(&state, now_ms()).await {
                Ok(0) => {}
                Ok(count) => tracing::debug!(count, "ran module timers"),
                Err(err) => tracing::warn!(error = %err, "module timer sweep failed"),
            }
        }
    });
}

/// Runs every timer due at `now` once, one at a time; returns how many ran.
pub async fn run_due(state: &AppState, now: i64) -> anyhow::Result<usize> {
    let mut ran = 0;
    for timer in state.store.take_due_module_timers(now, BATCH).await? {
        let Some(module) = state.store.installed_module(&timer.module_id).await? else {
            continue;
        };
        let Some(bot) = module.bot_user_id else {
            continue;
        };
        if !module.enabled
            || !schedule_approved(&module)
            || !declares_command(&module, &timer.command)
        {
            continue;
        }
        let request = RunRequest {
            caller: bot,
            command: &timer.command,
            input: &timer.input,
            kind: RunKind::Background,
            context: RunContext {
                channel: timer.channel_id,
                voice_channel: None,
            },
        };
        let surface = background_surface(state, &module, bot);
        match run_installed(state, &module, &request, surface).await {
            Ok(outcome) if outcome.ok => {}
            Ok(outcome) => {
                tracing::info!(module = %module.id, command = %timer.command, error = %outcome.payload, "module timer run failed");
            }
            Err(_) => {
                tracing::warn!(module = %module.id, command = %timer.command, "module timer run refused")
            }
        }
        ran += 1;
    }
    Ok(ran)
}
