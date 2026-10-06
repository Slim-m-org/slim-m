// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Tracks the single outstanding "somebody is being rung" attempt for a DM
//! channel.
//!
//! Deliberately in-memory and keyed on the channel alone, the same call
//! `heartbeat.rs` already makes for the SFU's own join bookkeeping: a ring is
//! meaningless the instant the process restarts, since the client racing
//! against it would already be gone too. A channel can only ever have one
//! live ring outstanding - starting a new one for a channel already ringing
//! replaces it outright, the same "latest attempt wins" shape a repeated
//! phone call to somebody already ringing would have anyway.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use crate::ids::{CallRingId, ChannelId, UserId};

/// How long an unanswered ring rings before [`CallRings::sweep_stale_at`]
/// gives up on it and the caller's own call is torn down.
///
/// A stated design choice, not derived from anything else: long enough that
/// a callee reaching for their phone is not cut off mid-glance, short enough
/// that a caller is not left sitting alone on an open SFU room for very
/// long. The client's own incoming-call UI mirrors this so its countdown
/// reaches zero at the same instant the server actually gives up, rather
/// than a client-only timer that stops showing the call slightly ahead of or
/// behind the caller's own side agreeing why.
pub const RING_TIMEOUT: Duration = Duration::from_secs(30);

struct RingState {
    ring_id: CallRingId,
    caller_id: UserId,
    callee_id: UserId,
    started_at: Instant,
}

/// One outstanding ring per DM channel, keyed on the channel.
#[derive(Clone, Default)]
pub struct CallRings {
    state: Arc<Mutex<HashMap<ChannelId, RingState>>>,
}

impl CallRings {
    pub fn new() -> Self {
        Self::default()
    }

    /// Starts a fresh ring, replacing whatever was outstanding for this
    /// channel; see this module's own doc for why replacing rather than
    /// refusing a second attempt is the right call.
    pub fn start(&self, channel_id: ChannelId, caller_id: UserId, callee_id: UserId) -> CallRingId {
        let ring_id = CallRingId::generate();
        lock(&self.state).insert(
            channel_id,
            RingState {
                ring_id,
                caller_id,
                callee_id,
                started_at: Instant::now(),
            },
        );
        ring_id
    }

    /// The callee answered (their first heartbeat for this channel landed
    /// while a ring naming them was outstanding): clears the ring and
    /// reports its id, or `None` if nothing was outstanding or it was not
    /// this user's own ring to answer - a stray heartbeat from somebody
    /// else must never cancel a ring that has nothing to do with them.
    ///
    /// Reports the caller alongside the ring id for the same reason
    /// [`Self::decline`] does: the call record this writes is attributed to
    /// whoever placed the call, and the callee is the only one here.
    pub fn answer(&self, channel_id: ChannelId, callee_id: UserId) -> Option<(CallRingId, UserId)> {
        self.take_if(channel_id, |ring| ring.callee_id == callee_id)
            .map(|ring| (ring.ring_id, ring.caller_id))
    }

    /// The callee explicitly declined, the same match rule [`Self::answer`]
    /// uses. Reports the ring id and the caller, so the caller's own
    /// dangling SFU participant can be evicted.
    pub fn decline(
        &self,
        channel_id: ChannelId,
        callee_id: UserId,
    ) -> Option<(CallRingId, UserId)> {
        self.take_if(channel_id, |ring| ring.callee_id == callee_id)
            .map(|ring| (ring.ring_id, ring.caller_id))
    }

    /// The caller hung up (or left the call) before it was answered - the
    /// mirror of [`Self::answer`], matched on the caller instead of the
    /// callee.
    pub fn cancel(&self, channel_id: ChannelId, caller_id: UserId) -> Option<CallRingId> {
        self.take_if(channel_id, |ring| ring.caller_id == caller_id)
            .map(|ring| ring.ring_id)
    }

    fn take_if(
        &self,
        channel_id: ChannelId,
        matches: impl Fn(&RingState) -> bool,
    ) -> Option<RingState> {
        let mut state = lock(&self.state);
        let matched = state.get(&channel_id).is_some_and(&matches);
        if matched {
            state.remove(&channel_id)
        } else {
            None
        }
    }

    /// Rings still waiting on `callee_id` as of `now`, newest first, as
    /// `(channel_id, ring_id, caller_id, time left)`. A ring past its timeout
    /// that the sweep has not yet collected is left out.
    pub fn outstanding_for_at(
        &self,
        callee_id: UserId,
        now: Instant,
    ) -> Vec<(ChannelId, CallRingId, UserId, Duration)> {
        let state = lock(&self.state);
        let mut found: Vec<_> = state
            .iter()
            .filter(|(_, ring)| ring.callee_id == callee_id)
            .filter_map(|(&channel_id, ring)| {
                let left = RING_TIMEOUT.checked_sub(now.duration_since(ring.started_at))?;
                Some((
                    ring.started_at,
                    channel_id,
                    ring.ring_id,
                    ring.caller_id,
                    left,
                ))
            })
            .collect();
        found.sort_by_key(|entry| std::cmp::Reverse(entry.0));
        found
            .into_iter()
            .map(|(_, channel, ring, caller, left)| (channel, ring, caller, left))
            .collect()
    }

    /// Every ring whose [`RING_TIMEOUT`] has passed as of `now`, removed and
    /// handed back as `(channel_id, ring_id, caller_id)` for the caller to
    /// publish the timeout and release the caller's own dangling SFU
    /// participant.
    pub fn sweep_stale_at(&self, now: Instant) -> Vec<(ChannelId, CallRingId, UserId)> {
        let mut state = lock(&self.state);
        let stale: Vec<ChannelId> = state
            .iter()
            .filter(|(_, ring)| now.duration_since(ring.started_at) >= RING_TIMEOUT)
            .map(|(&channel_id, _)| channel_id)
            .collect();
        stale
            .into_iter()
            .filter_map(|channel_id| {
                state
                    .remove(&channel_id)
                    .map(|ring| (channel_id, ring.ring_id, ring.caller_id))
            })
            .collect()
    }
}

/// A poisoned lock means another thread panicked mid-update; recover rather
/// than wedging every ring behind a dead tracker, the same choice
/// `heartbeat.rs`'s own `lock` makes.
fn lock(
    state: &Mutex<HashMap<ChannelId, RingState>>,
) -> MutexGuard<'_, HashMap<ChannelId, RingState>> {
    match state.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    }
}

/// How a ring ended, carried on [`crate::hub::Event::CallRingEnded`] so a
/// receiving client renders the right terminal state - declined, missed, or
/// the caller's own hangup - rather than a bare "the call is over" that
/// leaves the callee's screen to guess which happened.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CallRingOutcome {
    /// The callee joined the call before the timeout.
    Answered,
    /// The callee explicitly declined.
    Declined,
    /// The caller hung up, or left the call, before it was answered.
    Canceled,
    /// Nobody answered before [`RING_TIMEOUT`] elapsed.
    TimedOut,
}

impl CallRingOutcome {
    pub const fn as_str(self) -> &'static str {
        match self {
            CallRingOutcome::Answered => "answered",
            CallRingOutcome::Declined => "declined",
            CallRingOutcome::Canceled => "canceled",
            CallRingOutcome::TimedOut => "timed_out",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn uid() -> UserId {
        UserId::generate()
    }

    fn cid() -> ChannelId {
        ChannelId::generate()
    }

    #[test]
    fn the_callee_answering_clears_the_ring_and_reports_its_id() {
        let rings = CallRings::new();
        let (channel, caller, callee) = (cid(), uid(), uid());
        let ring_id = rings.start(channel, caller, callee);

        assert_eq!(
            rings.answer(channel, callee).map(|(id, _)| id),
            Some(ring_id)
        );
        // Answered rings do not answer twice.
        assert_eq!(rings.answer(channel, callee), None);
    }

    /// The sweep and an answer are mutually exclusive, whichever lands first.
    ///
    /// `http::voice::heartbeat` claims the ring BEFORE recording the join for
    /// exactly this reason. With the record first there was a window in which
    /// the sweep could take the ring after the callee had already joined,
    /// publishing `TimedOut` and evicting the caller while someone sat in the
    /// room alone. These two assertions are what makes that impossible: only
    /// one of the pair can ever succeed for a given ring.
    #[test]
    fn a_swept_ring_can_no_longer_be_answered() {
        let rings = CallRings::new();
        let (channel, caller, callee) = (cid(), uid(), uid());
        rings.start(channel, caller, callee);

        let swept = rings.sweep_stale_at(Instant::now() + RING_TIMEOUT);
        assert_eq!(swept.len(), 1, "sanity: the ring really did time out");
        assert_eq!(
            rings.answer(channel, callee),
            None,
            "a swept ring must not also report as answered"
        );
    }

    #[test]
    fn an_answered_ring_is_no_longer_there_for_the_sweep_to_time_out() {
        let rings = CallRings::new();
        let (channel, caller, callee) = (cid(), uid(), uid());
        rings.start(channel, caller, callee);

        assert!(rings.answer(channel, callee).is_some());
        assert!(
            rings
                .sweep_stale_at(Instant::now() + RING_TIMEOUT)
                .is_empty(),
            "an answered ring must not later be swept as timed out"
        );
    }

    #[test]
    fn a_ring_past_its_timeout_is_not_listed_as_outstanding() {
        let rings = CallRings::new();
        let (channel, caller, callee) = (cid(), uid(), uid());
        rings.start(channel, caller, callee);
        let now = Instant::now();

        assert_eq!(rings.outstanding_for_at(callee, now).len(), 1);
        assert!(rings.outstanding_for_at(caller, now).is_empty());
        assert!(
            rings
                .outstanding_for_at(callee, now + RING_TIMEOUT)
                .is_empty()
        );
    }

    #[test]
    fn a_stray_heartbeat_from_somebody_else_does_not_answer_the_ring() {
        let rings = CallRings::new();
        let (channel, caller, callee) = (cid(), uid(), uid());
        rings.start(channel, caller, callee);

        assert_eq!(rings.answer(channel, uid()), None, "not the named callee");
        // Still outstanding: a real answer from the actual callee still works.
        assert!(rings.answer(channel, callee).is_some());
    }

    #[test]
    fn declining_clears_the_ring_and_reports_the_caller_to_evict() {
        let rings = CallRings::new();
        let (channel, caller, callee) = (cid(), uid(), uid());
        let ring_id = rings.start(channel, caller, callee);

        assert_eq!(rings.decline(channel, callee), Some((ring_id, caller)));
        assert_eq!(rings.decline(channel, callee), None);
    }

    #[test]
    fn the_caller_canceling_is_matched_on_the_caller_not_the_callee() {
        let rings = CallRings::new();
        let (channel, caller, callee) = (cid(), uid(), uid());
        let ring_id = rings.start(channel, caller, callee);

        assert_eq!(rings.cancel(channel, callee), None, "not the caller");
        assert_eq!(rings.cancel(channel, caller), Some(ring_id));
    }

    #[test]
    fn starting_a_second_ring_for_the_same_channel_replaces_the_first() {
        let rings = CallRings::new();
        let (channel, caller, callee) = (cid(), uid(), uid());
        let first = rings.start(channel, caller, callee);
        let second = rings.start(channel, caller, callee);

        assert_ne!(first, second, "each attempt mints a fresh id");
        assert_eq!(
            rings.answer(channel, callee).map(|(id, _)| id),
            Some(second)
        );
    }

    #[test]
    fn a_ring_under_the_timeout_is_not_swept() {
        let rings = CallRings::new();
        let (channel, caller, callee) = (cid(), uid(), uid());
        rings.start(channel, caller, callee);

        assert!(
            rings
                .sweep_stale_at(Instant::now() + RING_TIMEOUT - Duration::from_secs(1))
                .is_empty()
        );
    }

    #[test]
    fn a_ring_past_the_timeout_is_swept_and_reports_the_caller() {
        let rings = CallRings::new();
        let (channel, caller, callee) = (cid(), uid(), uid());
        let ring_id = rings.start(channel, caller, callee);

        let past = Instant::now() + RING_TIMEOUT + Duration::from_secs(1);
        assert_eq!(rings.sweep_stale_at(past), [(channel, ring_id, caller)]);
        // Swept once, so a later pass over the same instant finds nothing left.
        assert!(rings.sweep_stale_at(past).is_empty());
    }

    #[test]
    fn every_outcome_has_a_distinct_stable_wire_string() {
        let strings: std::collections::HashSet<&str> = [
            CallRingOutcome::Answered,
            CallRingOutcome::Declined,
            CallRingOutcome::Canceled,
            CallRingOutcome::TimedOut,
        ]
        .map(CallRingOutcome::as_str)
        .into_iter()
        .collect();
        assert_eq!(strings.len(), 4);
    }
}
