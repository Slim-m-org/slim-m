// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The circuit breaker for runs the host starts (events and schedules): after
//! [`FAILURE_LIMIT`] failed runs in a row the module is disabled with a stated
//! reason and an audit row, and any success starts the count over.

use serde_json::json;

use super::AppState;
use super::module_commands::CommandOutcome;
use crate::module_runtime::RunError;
use crate::store::{InstalledModule, RunResult};

/// Consecutive failed background runs that turn a module off.
pub(crate) const FAILURE_LIMIT: i64 = 5;
/// The audit action for a module the breaker disabled.
pub(crate) const AUTO_DISABLE_ACTION: &str = "module.auto_disable";
const MAX_REASON_CHARS: usize = 300;

/// A full lane is the host's load, not the module's fault.
fn was_turned_away(outcome: &CommandOutcome) -> bool {
    outcome.host_failed && outcome.payload == RunError::Busy.to_string()
}

/// Counts one finished background run against `module`.
pub(super) async fn note_background_run(
    state: &AppState,
    module: &InstalledModule,
    result: &RunResult,
    outcome: Option<&CommandOutcome>,
) {
    if outcome.is_some_and(was_turned_away) {
        return;
    }
    let noted = match result {
        RunResult::Ok => state.store.record_module_background_ok(&module.id).await,
        RunResult::Failed(error) => count_failure(state, module, error).await,
    };
    if let Err(err) = noted {
        tracing::warn!(%err, module = %module.id, "could not update a module's failure count");
    }
}

async fn count_failure(
    state: &AppState,
    module: &InstalledModule,
    error: &str,
) -> anyhow::Result<()> {
    let streak = state
        .store
        .record_module_background_failure(&module.id)
        .await?;
    if streak < FAILURE_LIMIT {
        return Ok(());
    }
    let reason = disabled_reason(streak, error);
    if !state
        .store
        .disable_module_for_failures(&module.id, &reason)
        .await?
    {
        return Ok(());
    }
    tracing::warn!(module = %module.id, streak, "disabled a module after repeated failed runs");
    if let Some(actor) = module.bot_user_id {
        let detail = json!({ "consecutive_failures": streak }).to_string();
        state
            .store
            .record_admin_change(actor, AUTO_DISABLE_ACTION, Some(&module.id), &detail)
            .await?;
    }
    Ok(())
}

fn disabled_reason(streak: i64, error: &str) -> String {
    let text =
        format!("Turned off after {streak} failed background runs in a row. Last error: {error}");
    text.chars().take(MAX_REASON_CHARS).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_reason_is_bounded_and_names_the_streak() {
        let reason = disabled_reason(5, &"x".repeat(1000));
        assert_eq!(reason.chars().count(), MAX_REASON_CHARS);
        assert!(reason.contains("5 failed background runs"));
    }

    #[test]
    fn only_a_full_lane_is_not_the_modules_fault() {
        let busy = CommandOutcome::host_failure(RunError::Busy.to_string());
        let trap = CommandOutcome::host_failure("module trapped".into());
        assert!(was_turned_away(&busy));
        assert!(!was_turned_away(&trap));
    }
}
