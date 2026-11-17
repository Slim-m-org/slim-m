// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Tracks the single outstanding "somebody is being rung" attempt for a DM
//! channel: one callee in a pair, every other participant in a group.
//!
//! Deliberately in-memory and keyed on the channel alone, the same call
//! `heartbeat.rs` already makes for the SFU's own join bookkeeping: a ring is
//! meaningless the instant the process restarts, since the client racing
//! against it would already be gone too. A channel can only ever have one
//! live ring outstanding - starting a new one for a channel already ringing
//! replaces it outright, the same "latest attempt wins" shape a repeated
//! phone call to somebody already ringing would have anyway.
//!
//! A ring is only announced once its caller is in the call (their first
//! heartbeat), so nobody is ever rung into an empty room.

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
    callees: Vec<UserId>,
    /// When it was started, or announced once it was.
    started_at: Instant,
    announced: bool,
}

/// A ring [`CallRings::sweep_stale_at`] gave up on.
#[derive(Debug, PartialEq, Eq)]
pub struct StaleRing {
    pub channel_id: ChannelId,
    pub ring_id: CallRingId,
    pub caller_id: UserId,
    /// False when the caller never joined, so nobody was ever rung.
    pub announced: bool,
}

/// What a decline did to its ring.
#[derive(Debug, PartialEq, Eq)]
pub struct Declined {
    pub ring_id: CallRingId,
    pub caller_id: UserId,
    /// Nobody is left to answer, so the ring is over.
    pub ended: bool,
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
    /// refusing a second attempt is the right call. Reports the replaced
    /// ring's id and caller, so its end can be announced: otherwise the first
    /// caller's client keeps ringing out with nothing to tell it to stop.
    ///
    /// Nobody is rung yet: see [`Self::announce`].
    pub fn start(
        &self,
        channel_id: ChannelId,
        caller_id: UserId,
        callees: &[UserId],
    ) -> (CallRingId, Option<(CallRingId, UserId)>) {
        let ring_id = CallRingId::generate();
        let replaced = lock(&self.state).insert(
            channel_id,
            RingState {
                ring_id,
                caller_id,
                callees: callees.to_vec(),
                started_at: Instant::now(),
                announced: false,
            },
        );
        (ring_id, replaced.map(|ring| (ring.ring_id, ring.caller_id)))
    }

    /// The caller is in the call now, so the ring may go out: reports its id
    /// and callees the first time only, and restarts its timeout from here.
    pub fn announce(
        &self,
        channel_id: ChannelId,
        caller_id: UserId,
    ) -> Option<(CallRingId, Vec<UserId>)> {
        let mut state = lock(&self.state);
        let ring = state
            .get_mut(&channel_id)
            .filter(|ring| ring.caller_id == caller_id && !ring.announced)?;
        ring.announced = true;
        ring.started_at = Instant::now();
        Some((ring.ring_id, ring.callees.clone()))
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
        self.take_if(channel_id, |ring| ring.callees.contains(&callee_id))
            .map(|ring| (ring.ring_id, ring.caller_id))
    }

    /// The callee explicitly declined. A pair's only callee ending it is the
    /// whole ring; in a group the ring goes on for the others until the last
    /// one declines. `None` if nothing was outstanding for them.
    pub fn decline(&self, channel_id: ChannelId, callee_id: UserId) -> Option<Declined> {
        let mut state = lock(&self.state);
        let ring = state.get_mut(&channel_id)?;
        if !ring.callees.contains(&callee_id) {
            return None;
        }
        ring.callees.retain(|callee| *callee != callee_id);
        let (ring_id, caller_id) = (ring.ring_id, ring.caller_id);
        let ended = ring.callees.is_empty();
        if ended {
            state.remove(&channel_id);
        }
        Some(Declined {
            ring_id,
            caller_id,
            ended,
        })
    }

    /// The caller hung up (or left the call) before it was answered - the
    /// mirror of [`Self::answer`], matched on the caller instead of the
    /// callee. Also reports whether anybody was ever rung.
    pub fn cancel(&self, channel_id: ChannelId, caller_id: UserId) -> Option<(CallRingId, bool)> {
        self.take_if(channel_id, |ring| ring.caller_id == caller_id)
            .map(|ring| (ring.ring_id, ring.announced))
    }

    /// Removes whatever ring is outstanding for this channel, reporting its id
    /// and caller the way [`Self::start`] reports one it replaces.
    pub fn take(&self, channel_id: ChannelId) -> Option<(CallRingId, UserId)> {
        self.take_if(channel_id, |_| true)
            .map(|ring| (ring.ring_id, ring.caller_id))
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
            .filter(|(_, ring)| ring.announced && ring.callees.contains(&callee_id))
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
    /// handed back for the caller to publish the timeout and release the
    /// caller's own dangling SFU participant.
    pub fn sweep_stale_at(&self, now: Instant) -> Vec<StaleRing> {
        let mut state = lock(&self.state);
        let stale: Vec<ChannelId> = state
            .iter()
            .filter(|(_, ring)| now.duration_since(ring.started_at) >= RING_TIMEOUT)
            .map(|(&channel_id, _)| channel_id)
            .collect();
        stale
            .into_iter()
            .filter_map(|channel_id| {
                state.remove(&channel_id).map(|ring| StaleRing {
                    channel_id,
                    ring_id: ring.ring_id,
                    caller_id: ring.caller_id,
                    announced: ring.announced,
                })
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
mod tests;
