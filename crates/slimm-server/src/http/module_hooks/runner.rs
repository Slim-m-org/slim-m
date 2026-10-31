// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Running one hook as an ordinary module run on the hook lane. The module is
//! given no host calls, so it can only compute an answer from what it was sent.

use std::time::Duration;

use super::registry::Entry;
use crate::http::AppState;
use crate::http::module_run::{RunContext, RunKind, RunRequest, run_installed};
use crate::ids::UserId;
use crate::module_runtime::CapabilitySurface;

/// How one hook run ended.
pub(super) enum Verdict {
    /// The module answered; this is its reply text.
    Reply(String),
    /// The module trapped, ran out of budget, answered `ok:false` or answered nonsense.
    Failed(String),
    /// The run could not start or finish inside the chain's remaining time.
    Unavailable,
}

pub(super) async fn run(
    state: &AppState,
    entry: &Entry,
    (command, caller, input): (&str, UserId, &str),
    remaining: Duration,
) -> Verdict {
    let request = RunRequest {
        caller,
        command,
        input,
        kind: RunKind::Hook,
        context: RunContext::default(),
    };
    let run = run_installed(state, &entry.module, &request, CapabilitySurface::Disabled);
    match tokio::time::timeout(remaining, run).await {
        Err(_) => Verdict::Unavailable,
        Ok(Ok(outcome)) if outcome.ok => Verdict::Reply(outcome.payload),
        Ok(Ok(outcome)) if crate::http::module_breaker::was_turned_away(&outcome) => {
            Verdict::Unavailable
        }
        Ok(Ok(outcome)) => Verdict::Failed(super::short(&outcome.payload)),
        Ok(Err(_)) => Verdict::Failed("the module could not be started".into()),
    }
}
