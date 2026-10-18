// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Admission for photo compression: a job runs only when its estimated peak
//! memory fits in what the process can spare, so a burst of large photos
//! cannot push the server into swap or an OOM kill.

use std::sync::Arc;
use std::time::Duration;

use tokio::sync::{OwnedSemaphorePermit, Semaphore};

const UNIT: u64 = 1024 * 1024;
const MIB: u64 = UNIT;

/// Memory kept for everything else in the server (connections, SQLite, uploads in flight).
const MIN_HEADROOM: u64 = 96 * MIB;

/// What compression may use when no memory limit is discoverable.
const UNLIMITED_BUDGET: u64 = 1024 * MIB;

/// How long a job waits for room before its upload is stored as sent.
const DEFAULT_WAIT: Duration = Duration::from_secs(30);

/// Bytes of estimated peak memory compression may hold at once.
#[derive(Debug, Clone)]
pub struct MemoryBudget {
    semaphore: Arc<Semaphore>,
    total_units: usize,
    wait: Duration,
}

impl MemoryBudget {
    /// A budget of `total_bytes`, whose waiting jobs give up after `wait`.
    pub fn new(total_bytes: u64, wait: Duration) -> Self {
        let total_units = usize::try_from(total_bytes / UNIT).unwrap_or(usize::MAX >> 4);
        Self {
            semaphore: Arc::new(Semaphore::new(total_units)),
            total_units,
            wait,
        }
    }

    /// Sized from the memory limit this process runs under, less headroom for the rest of the server.
    pub fn for_limit(limit: Option<u64>) -> Self {
        let total = limit.map_or(UNLIMITED_BUDGET, |limit| {
            limit.saturating_sub(MIN_HEADROOM.max(limit / 4))
        });
        Self::new(total, DEFAULT_WAIT)
    }

    /// Reserves `estimate` bytes until the permit drops. `None` when the job can
    /// never fit, or no room opened up in time: the caller stores the upload as sent.
    pub async fn admit(&self, estimate: u64) -> Option<OwnedSemaphorePermit> {
        let units = usize::try_from(estimate.div_ceil(UNIT)).ok()?.max(1);
        if units > self.total_units {
            return None;
        }
        let units = u32::try_from(units).ok()?;
        tokio::time::timeout(self.wait, self.semaphore.clone().acquire_many_owned(units))
            .await
            .ok()?
            .ok()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SHORT: Duration = Duration::from_millis(50);

    #[tokio::test]
    async fn a_job_larger_than_the_whole_budget_is_refused_at_once() {
        let budget = MemoryBudget::new(10 * MIB, Duration::from_secs(60));
        assert!(budget.admit(11 * MIB).await.is_none());
        assert!(budget.admit(10 * MIB).await.is_some());
    }

    #[tokio::test]
    async fn a_job_waits_for_room_and_gives_up_after_the_wait() {
        let budget = MemoryBudget::new(10 * MIB, SHORT);
        let first = budget.admit(8 * MIB).await.unwrap();
        assert!(
            budget.admit(4 * MIB).await.is_none(),
            "no room within the wait"
        );
        drop(first);
        assert!(budget.admit(4 * MIB).await.is_some());
    }

    #[tokio::test]
    async fn a_queued_job_runs_when_the_running_one_finishes() {
        let budget = MemoryBudget::new(10 * MIB, Duration::from_secs(30));
        let first = budget.admit(8 * MIB).await.unwrap();
        let waiting = tokio::spawn({
            let budget = budget.clone();
            async move { budget.admit(8 * MIB).await.is_some() }
        });
        tokio::task::yield_now().await;
        assert!(!waiting.is_finished());
        drop(first);
        assert!(waiting.await.unwrap());
    }

    #[test]
    fn the_budget_leaves_headroom_below_the_limit() {
        let to_units = |b: &MemoryBudget| b.total_units as u64;
        assert_eq!(to_units(&MemoryBudget::for_limit(Some(512 * MIB))), 384);
        assert_eq!(to_units(&MemoryBudget::for_limit(Some(256 * MIB))), 160);
        assert_eq!(to_units(&MemoryBudget::for_limit(Some(64 * MIB))), 0);
        assert_eq!(to_units(&MemoryBudget::for_limit(None)), 1024);
    }
}
