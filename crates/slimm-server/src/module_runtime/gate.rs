// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A process-wide cap on module runs in flight. Each run builds its own store
//! of up to the manifest's memory ceiling on a blocking thread, so a few
//! members using a heavy module at once must queue rather than stack memory.

use std::sync::{Arc, OnceLock};
use std::time::Duration;

use tokio::sync::{OwnedSemaphorePermit, Semaphore};

use super::host::RunError;

/// Runs that may execute at once, across every module.
pub(super) const MAX_CONCURRENT_RUNS: usize = 4;
/// How long a run waits for a free slot before it is turned away.
pub(super) const QUEUE_WAIT: Duration = Duration::from_secs(3);

/// Runs nobody invoked (events, schedules) that may execute at once; separate
/// from the slots members' commands use, so a busy lane never delays a command.
pub(super) const MAX_BACKGROUND_RUNS: usize = 2;
/// How long a background run waits for its lane; long, since it is queued work and not a person.
pub(super) const BACKGROUND_QUEUE_WAIT: Duration = Duration::from_secs(60);

/// Which pool of run slots a run draws from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RunLane {
    /// A member invoked the command and is waiting for the answer.
    Member,
    /// The host started the run: a pushed event or a schedule.
    Background,
}

pub(super) struct RunGate {
    permits: Arc<Semaphore>,
    wait: Duration,
}

impl RunGate {
    pub(super) fn new(slots: usize, wait: Duration) -> Self {
        Self {
            permits: Arc::new(Semaphore::new(slots)),
            wait,
        }
    }

    /// A slot, held until dropped; `Busy` when none frees up in time.
    pub(super) async fn acquire(&self) -> Result<OwnedSemaphorePermit, RunError> {
        let waiting = self.permits.clone().acquire_owned();
        match tokio::time::timeout(self.wait, waiting).await {
            Ok(Ok(permit)) => Ok(permit),
            _ => Err(RunError::Busy),
        }
    }
}

pub(super) fn shared(lane: RunLane) -> &'static RunGate {
    static MEMBER: OnceLock<RunGate> = OnceLock::new();
    static BACKGROUND: OnceLock<RunGate> = OnceLock::new();
    match lane {
        RunLane::Member => MEMBER.get_or_init(|| RunGate::new(MAX_CONCURRENT_RUNS, QUEUE_WAIT)),
        RunLane::Background => {
            BACKGROUND.get_or_init(|| RunGate::new(MAX_BACKGROUND_RUNS, BACKGROUND_QUEUE_WAIT))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn a_run_past_the_cap_is_turned_away_and_a_freed_slot_is_reusable() {
        let gate = RunGate::new(2, Duration::from_millis(50));
        let first = gate.acquire().await.unwrap();
        let _second = gate.acquire().await.unwrap();
        assert!(matches!(gate.acquire().await, Err(RunError::Busy)));
        drop(first);
        assert!(gate.acquire().await.is_ok());
    }
}
