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

pub(super) fn shared() -> &'static RunGate {
    static GATE: OnceLock<RunGate> = OnceLock::new();
    GATE.get_or_init(|| RunGate::new(MAX_CONCURRENT_RUNS, QUEUE_WAIT))
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
