// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A process-wide cap on module runs in flight. Each run builds its own store
//! of up to the manifest's memory ceiling on a blocking thread, so a few
//! members using a heavy module at once must queue rather than stack memory.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock, PoisonError};
use std::time::Duration;

use tokio::sync::{OwnedSemaphorePermit, Semaphore};

use super::host::RunError;
use crate::ids::UserId;

/// Runs that may execute at once, across every module.
pub(super) const MAX_CONCURRENT_RUNS: usize = 4;
/// How long a run waits for a free slot before it is turned away.
pub(super) const QUEUE_WAIT: Duration = Duration::from_secs(3);

/// Member-lane runs one member may hold at once, so one account at the rate limit cannot occupy every slot.
pub(super) const MAX_RUNS_PER_MEMBER: usize = 2;

/// Runs nobody invoked (events, schedules) that may execute at once; separate
/// from the slots members' commands use, so a busy lane never delays a command.
pub(super) const MAX_BACKGROUND_RUNS: usize = 2;
/// How long a background run waits for its lane; long, since it is queued work and not a person.
pub(super) const BACKGROUND_QUEUE_WAIT: Duration = Duration::from_secs(60);

/// Slot fills (profile sections, member badges) that may execute at once, in a lane of their own
/// so neither members' commands nor events wait on them, nor they on events.
pub(super) const MAX_SLOT_RUNS: usize = 2;
/// A slot fill is decoration on a page someone is loading, so it gives up quickly and shows nothing.
pub(super) const SLOT_QUEUE_WAIT: Duration = Duration::from_secs(2);

/// Hook runs (interceptors and permission checks) that may execute at once, in a lane of their own
/// so a message send never waits behind a command or an event.
pub(super) const MAX_HOOK_RUNS: usize = 4;
/// A hook is on a member's send path, so it gives up fast rather than hold the send.
pub(super) const HOOK_QUEUE_WAIT: Duration = Duration::from_millis(50);

/// Which pool of run slots a run draws from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RunLane {
    /// A member invoked the command and is waiting for the answer.
    Member,
    /// As [`Member`](Self::Member), for a known member, who may hold only [`MAX_RUNS_PER_MEMBER`] slots.
    MemberOf(UserId),
    /// The host started the run: a pushed event or a schedule.
    Background,
    /// A slot fill for a member viewing a profile or member list.
    Slot,
    /// A hook on a member's action: a message interceptor or a permission check.
    Hook,
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

/// How many runs each member has in flight on the member lane.
pub(super) struct MemberCap {
    limit: usize,
    held: Mutex<HashMap<UserId, Arc<Semaphore>>>,
}

impl MemberCap {
    /// Entries kept before the idle ones are dropped.
    const PRUNE_ABOVE: usize = 256;

    pub(super) fn new(limit: usize) -> Self {
        Self {
            limit,
            held: Mutex::new(HashMap::new()),
        }
    }

    /// A share of the lane for `member`, held until dropped; waits while they hold their limit.
    async fn acquire(&self, member: UserId) -> Result<OwnedSemaphorePermit, RunError> {
        let semaphore = {
            let mut held = self.held.lock().unwrap_or_else(PoisonError::into_inner);
            if held.len() > Self::PRUNE_ABOVE {
                held.retain(|_, semaphore| Arc::strong_count(semaphore) > 1);
            }
            Arc::clone(
                held.entry(member)
                    .or_insert_with(|| Arc::new(Semaphore::new(self.limit))),
            )
        };
        semaphore.acquire_owned().await.map_err(|_| RunError::Busy)
    }
}

/// A run's claim on its lane, and on its member's share of it; both free when it drops.
pub(super) struct RunSlot {
    _lane: OwnedSemaphorePermit,
    _member: Option<OwnedSemaphorePermit>,
}

/// Admits a run to `gate`; with a `member`, they must first hold one of their own shares.
pub(super) async fn admit(
    gate: &RunGate,
    member: Option<(&MemberCap, UserId)>,
) -> Result<RunSlot, RunError> {
    let Some((cap, who)) = member else {
        return Ok(RunSlot {
            _lane: gate.acquire().await?,
            _member: None,
        });
    };
    let both = async {
        let share = cap.acquire(who).await?;
        Ok(RunSlot {
            _lane: gate.acquire().await?,
            _member: Some(share),
        })
    };
    tokio::time::timeout(gate.wait, both)
        .await
        .unwrap_or(Err(RunError::Busy))
}

/// A slot on `lane`, however long it takes to be given one within the lane's wait.
pub(super) async fn acquire(lane: RunLane) -> Result<RunSlot, RunError> {
    static MEMBERS: OnceLock<MemberCap> = OnceLock::new();
    match lane {
        RunLane::MemberOf(who) => {
            let cap = MEMBERS.get_or_init(|| MemberCap::new(MAX_RUNS_PER_MEMBER));
            admit(shared(lane), Some((cap, who))).await
        }
        _ => admit(shared(lane), None).await,
    }
}

fn shared(lane: RunLane) -> &'static RunGate {
    static MEMBER: OnceLock<RunGate> = OnceLock::new();
    static BACKGROUND: OnceLock<RunGate> = OnceLock::new();
    static SLOT: OnceLock<RunGate> = OnceLock::new();
    static HOOK: OnceLock<RunGate> = OnceLock::new();
    match lane {
        RunLane::Member | RunLane::MemberOf(_) => {
            MEMBER.get_or_init(|| RunGate::new(MAX_CONCURRENT_RUNS, QUEUE_WAIT))
        }
        RunLane::Background => {
            BACKGROUND.get_or_init(|| RunGate::new(MAX_BACKGROUND_RUNS, BACKGROUND_QUEUE_WAIT))
        }
        RunLane::Slot => SLOT.get_or_init(|| RunGate::new(MAX_SLOT_RUNS, SLOT_QUEUE_WAIT)),
        RunLane::Hook => HOOK.get_or_init(|| RunGate::new(MAX_HOOK_RUNS, HOOK_QUEUE_WAIT)),
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

    fn member_lane() -> (RunGate, MemberCap) {
        (
            RunGate::new(4, Duration::from_millis(80)),
            MemberCap::new(MAX_RUNS_PER_MEMBER),
        )
    }

    #[tokio::test]
    async fn one_member_cannot_hold_more_than_their_share_of_the_lane() {
        let (gate, cap) = member_lane();
        let (hog, other) = (UserId::generate(), UserId::generate());
        let first = admit(&gate, Some((&cap, hog))).await.unwrap();
        let _second = admit(&gate, Some((&cap, hog))).await.unwrap();

        assert!(
            matches!(admit(&gate, Some((&cap, hog))).await, Err(RunError::Busy)),
            "a third run waits on the member's own share, not on the lane"
        );
        let _a = admit(&gate, Some((&cap, other))).await.unwrap();
        let _b = admit(&gate, Some((&cap, other))).await.unwrap();

        drop(first);
        assert!(admit(&gate, Some((&cap, hog))).await.is_ok());
    }

    #[tokio::test]
    async fn a_run_waiting_on_its_own_share_goes_when_one_frees() {
        let (gate, cap) = member_lane();
        let member = UserId::generate();
        let first = admit(&gate, Some((&cap, member))).await.unwrap();
        let _second = admit(&gate, Some((&cap, member))).await.unwrap();

        let waiting = admit(&gate, Some((&cap, member)));
        let release = async {
            tokio::time::sleep(Duration::from_millis(20)).await;
            drop(first);
        };
        let (admitted, ()) = tokio::join!(waiting, release);
        assert!(admitted.is_ok());
    }

    #[tokio::test]
    async fn a_member_share_is_released_with_the_slot() {
        let (gate, cap) = member_lane();
        let member = UserId::generate();
        for _ in 0..5 {
            let slot = admit(&gate, Some((&cap, member))).await.unwrap();
            drop(slot);
        }
        assert_eq!(gate.permits.available_permits(), 4);
    }

    #[tokio::test]
    async fn idle_members_are_dropped_from_the_map_once_it_grows() {
        let cap = MemberCap::new(1);
        let gate = RunGate::new(4, Duration::from_millis(80));
        for _ in 0..=MemberCap::PRUNE_ABOVE {
            let slot = admit(&gate, Some((&cap, UserId::generate())))
                .await
                .unwrap();
            drop(slot);
        }
        let _held = admit(&gate, Some((&cap, UserId::generate())))
            .await
            .unwrap();
        assert_eq!(cap.held.lock().unwrap().len(), 1);
    }
}
