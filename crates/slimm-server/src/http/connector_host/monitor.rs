// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Keeps what the supervisor runs matching what the server has enabled (decision 0134): asks
//! `hello` with backoff while it is away, and on every tick creates what is missing, starts
//! what should run, restarts crashes with backoff, turns off a connector that keeps
//! crashing, stops what is disabled and removes labelled containers it has no record of.

use std::collections::HashMap;
use std::time::Duration;

use serde_json::json;

use super::client::Listed;
use super::crashes::Decision;
use super::{Health, HostRun};
use crate::http::AppState;
use crate::store::HostRun as HostRunRecord;
use crate::store::TurnedOff;

const TICK: Duration = Duration::from_secs(5);
const FIRST_RETRY: Duration = Duration::from_secs(1);
const MAX_RETRY: Duration = Duration::from_secs(30);

/// Runs until the process ends; a no-op when the operator has not configured the supervisor.
pub fn spawn_monitor(state: AppState) {
    let Some(runner) = state.dock.host_run() else {
        return;
    };
    tokio::spawn(async move {
        let mut retry = FIRST_RETRY;
        loop {
            let wait = if pass(&state, &runner).await {
                retry = FIRST_RETRY;
                TICK
            } else {
                let wait = retry;
                retry = (retry * 2).min(MAX_RETRY);
                wait
            };
            let _ = tokio::time::timeout(wait, runner.wake.notified()).await;
        }
    });
}

/// One pass of the monitor, for a test to drive without waiting on its timer.
#[doc(hidden)]
pub async fn tick(state: &AppState) {
    if let Some(runner) = state.dock.host_run() {
        pass(state, &runner).await;
    }
}

/// Asks `hello`, then reconciles; answers whether the supervisor answered.
async fn pass(state: &AppState, runner: &HostRun) -> bool {
    match runner.client.hello().await {
        Ok(hello) => {
            runner.set_health(Health::Up(hello));
            reconcile(state, runner).await;
            true
        }
        Err(err) => {
            runner.set_health(Health::Down(err.detail().to_owned()));
            false
        }
    }
}

/// One pass over every host-run connector; public to the crate so a test can drive it.
pub(crate) async fn reconcile(state: &AppState, runner: &HostRun) {
    if runner.unavailable_reason().is_some() {
        return;
    }
    let _pass = runner.pause_monitor().await;
    let (Ok(records), Ok(listed)) = (state.store.host_runs().await, runner.client.list().await)
    else {
        return;
    };
    let by_id: HashMap<&str, &Listed> = listed.iter().map(|l| (l.id.as_str(), l)).collect();
    for record in &records {
        reconcile_one(
            state,
            runner,
            record,
            by_id.get(record.run_id.as_str()).copied(),
        )
        .await;
    }
    for orphan in listed
        .iter()
        .filter(|l| !records.iter().any(|r| r.run_id == l.id))
    {
        tracing::warn!(run = %orphan.id, "removing a connector container the server has no record of; its volume is kept");
        if let Err(err) = runner.client.remove(&orphan.id, true).await {
            tracing::warn!(run = %orphan.id, reason = err.detail(), "could not remove an orphaned connector container");
        }
    }
}

async fn reconcile_one(
    state: &AppState,
    runner: &HostRun,
    record: &HostRunRecord,
    listed: Option<&Listed>,
) {
    let should_run = record.enabled && !record.refused && record.crash_disabled_at.is_none();
    let running = listed.is_some_and(|l| l.state == "running");
    runner.set_running(&record.module_id, running);
    if !should_run {
        if running && let Err(err) = runner.client.stop(&record.run_id).await {
            tracing::warn!(module = %record.module_id, reason = err.detail(), "could not stop a disabled connector");
        }
        return;
    }
    if let Some(full) = listed.filter(|l| l.volume_over_limit) {
        return disable_for_volume(state, runner, record, full).await;
    }
    if let Some(exited) = listed.filter(|l| l.state == "exited") {
        let finished = exited.finished_at.clone().unwrap_or_default();
        let decision = runner
            .crashes
            .lock()
            .map(|mut c| {
                c.entry(record.module_id.clone())
                    .or_default()
                    .on_exited(&finished, crate::store::now_ms())
            })
            .unwrap_or(Decision::Wait);
        match decision {
            Decision::Disable { crashes } => {
                return disable_for_crashes(state, runner, record, crashes).await;
            }
            Decision::Wait => return,
            Decision::StartNow => {}
        }
    }
    let now = crate::store::now_ms();
    if running || !runner.retry_due(&record.module_id, now) {
        return;
    }
    let result = runner.ensure_running(state, record, listed).await;
    runner.note_attempt(&record.module_id, result.is_ok(), now);
    runner.note(state, &record.module_id, &result).await;
}

/// Turned off with the crash breaker's alert and audit row, and refused until an admin
/// frees space or approves more: the supervisor already stopped it.
async fn disable_for_volume(
    state: &AppState,
    runner: &HostRun,
    record: &HostRunRecord,
    listed: &Listed,
) {
    let limit = record
        .spec
        .volume_mib
        .map_or_else(|| "its".to_owned(), |m| format!("its {m} MiB"));
    let reason = format!("Turned off because its data volume passed {limit} limit.");
    let detail = json!({ "volume_bytes": listed.volume_bytes, "volume_mib": record.spec.volume_mib, "host_run": true });
    turn_off(
        state,
        runner,
        record,
        (&reason, TurnedOff::VolumeFull),
        detail,
    )
    .await;
}

/// The same alert and audit row the module breaker sends (decision 0091), with the
/// connector's own principal as the actor, since no person turned it off.
async fn disable_for_crashes(
    state: &AppState,
    runner: &HostRun,
    record: &HostRunRecord,
    crashes: usize,
) {
    let reason = format!("Turned off after {crashes} crashes within 10 minutes.");
    let at = crate::store::now_ms();
    let detail = json!({ "crashes": crashes, "host_run": true });
    turn_off(
        state,
        runner,
        record,
        (&reason, TurnedOff::Crashes { at }),
        detail,
    )
    .await;
}

async fn turn_off(
    state: &AppState,
    runner: &HostRun,
    record: &HostRunRecord,
    (reason, why): (&str, TurnedOff),
    detail: serde_json::Value,
) {
    if let Err(err) = state
        .store
        .turn_off_host_run(&record.module_id, reason, why)
        .await
    {
        tracing::warn!(%err, module = %record.module_id, "could not turn off a connector");
        return;
    }
    let _ = runner.client.stop(&record.run_id).await;
    tracing::warn!(module = %record.module_id, reason, "turned off a host-run connector");
    let name = state
        .store
        .installed_module(&record.module_id)
        .await
        .ok()
        .flatten()
        .map_or_else(|| record.module_id.clone(), |m| m.name);
    crate::admin_alerts::Notifier::from_state(state)
        .raise(
            crate::admin_alerts::AlertKind::ModuleBreaker,
            &record.module_id,
            &format!("{name}: {reason}"),
        )
        .await;
    if let Some(actor) = record.principal {
        let action = crate::http::module_breaker::AUTO_DISABLE_ACTION;
        if let Err(err) = state
            .store
            .record_admin_change(actor, action, Some(&record.module_id), &detail.to_string())
            .await
        {
            tracing::warn!(%err, module = %record.module_id, "could not record a connector's automatic disable");
        }
    }
}
