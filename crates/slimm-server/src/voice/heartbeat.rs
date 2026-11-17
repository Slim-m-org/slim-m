// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Bounds how long a terminated app can leave a ghost participant in a room.
//!
//! A LiveKit room reaps a dead connection on its own once ICE gives up on it,
//! but that is an SFU implementation default this project does not set and
//! should not lean on: it is what a device that is genuinely killed (no
//! socket close, no goodbye, nothing) leaves behind, and how long it takes is
//! whatever the SFU's own tuning happens to be. [`CallHeartbeats`] is the
//! owned, tested backstop: a client still on a call keeps refreshing its
//! entry (`POST .../voice/heartbeat`, on a plain interval, independent of
//! app-foreground state so a backgrounded call is never mistaken for a dead
//! one), and [`CallHeartbeats::sweep_stale_at`] hands back everyone whose
//! refresh has gone quiet for longer than a real client, even a briefly
//! reconnecting one, plausibly would.
//!
//! Deliberately in-memory, the same call [`crate::presence::PresenceTracker`]
//! makes: a row per heartbeat would be pure write amplification for a value
//! that means nothing the instant a process restarts anyway, since every
//! LiveKit connection it could describe would already be gone too.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use crate::ids::{ChannelId, UserId};

/// Mirrors `voice_controller.dart`'s `voiceHeartbeatInterval` default. Kept as
/// its own named constant, rather than a bare number folded into
/// [`STALE_AFTER`], so that value is derived from this one at compile time
/// instead of the two being tied only by two doc comments agreeing by luck.
/// Still has to be updated by hand if the Dart default ever changes; deriving
/// [`STALE_AFTER`] from it is what makes that the only number to change.
const CLIENT_HEARTBEAT_INTERVAL: Duration = Duration::from_secs(15);

/// How long a heartbeat may go unrefreshed before [`CallHeartbeats::sweep_stale_at`]
/// gives it up. 8/3 of [`CLIENT_HEARTBEAT_INTERVAL`] (40s at the current
/// 15s), so one dropped request under a flaky connection does not evict
/// somebody still genuinely on the call.
pub const STALE_AFTER: Duration = Duration::from_secs(CLIENT_HEARTBEAT_INTERVAL.as_secs() * 8 / 3);

/// How recent a heartbeat must be to count as being in the call when deciding
/// who to ring: one late beat, well short of the eviction sweep's [`STALE_AFTER`].
pub const IN_CALL_WITHIN: Duration =
    Duration::from_millis(CLIENT_HEARTBEAT_INTERVAL.as_millis() as u64 * 3 / 2);

/// Tracks the last heartbeat seen for each `(user, channel)` voice session.
#[derive(Clone, Default)]
pub struct CallHeartbeats {
    state: Arc<Mutex<HashMap<(UserId, ChannelId), Instant>>>,
}

impl CallHeartbeats {
    pub fn new() -> Self {
        Self::default()
    }

    /// Records a heartbeat now, creating the entry on its first one. A test's
    /// tool for putting an entry in place directly; a live caller wants
    /// [`Self::record_reporting_new`] instead, which is this same write
    /// plus the answer to whether it was the first one.
    pub fn record_at(&self, user_id: UserId, channel_id: ChannelId, now: Instant) {
        lock(&self.state).insert((user_id, channel_id), now);
    }

    /// [`Self::record_at`] with the real clock, reporting whether the entry
    /// was newly created - a single lock-held check-and-insert, so two
    /// concurrent first heartbeats for the same `(user, channel)` cannot
    /// both observe "not present yet" and both report a join. Use this
    /// rather than [`Self::contains`] followed by [`Self::record_at`],
    /// which is exactly that race: the check and the write are two separate
    /// lock acquisitions, so a second caller can slip in between them.
    pub fn record_reporting_new(&self, user_id: UserId, channel_id: ChannelId) -> bool {
        self.record_reporting_new_at(user_id, channel_id, Instant::now())
    }

    /// [`Self::record_reporting_new`] with an explicit clock, so a test can
    /// drive it deterministically instead of sleeping.
    pub fn record_reporting_new_at(
        &self,
        user_id: UserId,
        channel_id: ChannelId,
        now: Instant,
    ) -> bool {
        lock(&self.state)
            .insert((user_id, channel_id), now)
            .is_none()
    }

    /// Whether an entry exists at all, regardless of freshness. For a test
    /// to confirm a handler actually reached [`Self::record_at`]; a live
    /// caller deciding whether to publish a signal wants
    /// [`Self::record_reporting_new`] or [`Self::forget_reporting_removed`]
    /// instead, which answer the same question without the race a separate
    /// read-then-write opens.
    pub fn contains(&self, user_id: UserId, channel_id: ChannelId) -> bool {
        lock(&self.state).contains_key(&(user_id, channel_id))
    }

    /// Everyone on `channel_id` whose last heartbeat is under `within` old as of `now`.
    pub fn fresh_in_at(
        &self,
        channel_id: ChannelId,
        within: Duration,
        now: Instant,
    ) -> Vec<UserId> {
        lock(&self.state)
            .iter()
            .filter(|&(&(_, channel), &last)| {
                channel == channel_id && now.duration_since(last) < within
            })
            .map(|(&(user, _), _)| user)
            .collect()
    }

    /// Drops a tracked session outright, e.g. once it has already been
    /// evicted for some other reason (a kick, a ban): a later sweep then has
    /// nothing stale left to rediscover and call the SFU about again.
    pub fn forget(&self, user_id: UserId, channel_id: ChannelId) {
        lock(&self.state).remove(&(user_id, channel_id));
    }

    /// [`Self::forget`], reporting whether there was an entry to drop - a
    /// single lock-held check-and-remove, mirroring
    /// [`Self::record_reporting_new`], so two concurrent real hangups for
    /// the same `(user, channel)` cannot both observe "still present" and
    /// both report a hangup.
    pub fn forget_reporting_removed(&self, user_id: UserId, channel_id: ChannelId) -> bool {
        lock(&self.state).remove(&(user_id, channel_id)).is_some()
    }

    /// Removes and returns every session whose last heartbeat is at least
    /// `threshold` old as of `now`.
    pub fn sweep_stale_at(&self, threshold: Duration, now: Instant) -> Vec<(UserId, ChannelId)> {
        let mut state = lock(&self.state);
        let stale: Vec<_> = state
            .iter()
            .filter(|&(_, &last)| now.duration_since(last) >= threshold)
            .map(|(&key, _)| key)
            .collect();
        for key in &stale {
            state.remove(key);
        }
        stale
    }
}

/// A poisoned lock means another thread panicked mid-update; recover rather
/// than wedging every heartbeat behind a dead tracker, the choice
/// [`crate::presence::PresenceTracker`] and [`crate::ratelimit::RateLimiter`]
/// both already make.
fn lock(
    state: &Mutex<HashMap<(UserId, ChannelId), Instant>>,
) -> MutexGuard<'_, HashMap<(UserId, ChannelId), Instant>> {
    match state.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
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
    fn a_fresh_heartbeat_is_not_stale() {
        let heartbeats = CallHeartbeats::new();
        let (user, channel) = (uid(), cid());
        let now = Instant::now();
        heartbeats.record_at(user, channel, now);

        assert!(heartbeats.sweep_stale_at(STALE_AFTER, now).is_empty());
    }

    #[test]
    fn a_heartbeat_that_stops_arriving_goes_stale() {
        let heartbeats = CallHeartbeats::new();
        let (user, channel) = (uid(), cid());
        let start = Instant::now();
        heartbeats.record_at(user, channel, start);

        let past = start + STALE_AFTER + Duration::from_secs(1);
        assert_eq!(
            heartbeats.sweep_stale_at(STALE_AFTER, past),
            [(user, channel)]
        );
    }

    #[test]
    fn a_refreshed_heartbeat_survives_past_the_old_deadline() {
        let heartbeats = CallHeartbeats::new();
        let (user, channel) = (uid(), cid());
        let start = Instant::now();
        heartbeats.record_at(user, channel, start);

        // A backgrounded-but-alive call: the refresh lands before the deadline.
        let refreshed_at = start + Duration::from_secs(5);
        heartbeats.record_at(user, channel, refreshed_at);

        let past_old_deadline = start + STALE_AFTER + Duration::from_secs(1);
        assert!(
            heartbeats
                .sweep_stale_at(STALE_AFTER, past_old_deadline)
                .is_empty(),
            "the refresh must count from its own timestamp, not the first one"
        );
    }

    #[test]
    fn a_swept_entry_is_removed_so_it_is_not_reported_twice() {
        let heartbeats = CallHeartbeats::new();
        let (user, channel) = (uid(), cid());
        let start = Instant::now();
        heartbeats.record_at(user, channel, start);

        let past = start + STALE_AFTER + Duration::from_secs(1);
        assert_eq!(heartbeats.sweep_stale_at(STALE_AFTER, past).len(), 1);
        assert!(heartbeats.sweep_stale_at(STALE_AFTER, past).is_empty());
    }

    /// The derivation ties the two constants together, but not to any
    /// particular ratio; this is what fails if the multiplier is ever
    /// narrowed to something that no longer survives one missed beat.
    #[test]
    fn stale_after_leaves_real_margin_over_a_missed_client_beat() {
        assert!(STALE_AFTER >= CLIENT_HEARTBEAT_INTERVAL * 2);
    }

    #[test]
    fn forgetting_an_entry_stops_it_from_ever_going_stale() {
        let heartbeats = CallHeartbeats::new();
        let (user, channel) = (uid(), cid());
        let start = Instant::now();
        heartbeats.record_at(user, channel, start);
        heartbeats.forget(user, channel);

        let past = start + STALE_AFTER + Duration::from_secs(1);
        assert!(heartbeats.sweep_stale_at(STALE_AFTER, past).is_empty());
    }

    #[test]
    fn record_reporting_new_is_true_only_for_the_first_call() {
        let heartbeats = CallHeartbeats::new();
        let (user, channel) = (uid(), cid());

        assert!(heartbeats.record_reporting_new(user, channel));
        assert!(!heartbeats.record_reporting_new(user, channel));
        assert!(!heartbeats.record_reporting_new(user, channel));
    }

    #[test]
    fn forget_reporting_removed_is_true_only_when_something_was_there() {
        let heartbeats = CallHeartbeats::new();
        let (user, channel) = (uid(), cid());

        assert!(!heartbeats.forget_reporting_removed(user, channel));

        heartbeats.record_at(user, channel, Instant::now());
        assert!(heartbeats.forget_reporting_removed(user, channel));
        assert!(!heartbeats.forget_reporting_removed(user, channel));
    }

    /// The property `http::voice`'s handlers depend on: many callers racing
    /// the same `(user, channel)` pair's first heartbeat must still see
    /// exactly one of them report a real join. A separate check-then-write
    /// (`contains` followed by `record_at`) cannot promise this - a second
    /// caller can slip between the two lock acquisitions - which is exactly
    /// the shape this single lock-held method exists to close. A
    /// [`std::sync::Barrier`] lines every thread up at the same instant so
    /// the race is real rather than merely possible.
    #[test]
    fn only_one_of_many_concurrent_first_heartbeats_reports_new() {
        let heartbeats = CallHeartbeats::new();
        let (user, channel) = (uid(), cid());
        const THREADS: usize = 64;
        let barrier = std::sync::Barrier::new(THREADS);

        let new_count: usize = std::thread::scope(|scope| {
            let handles: Vec<_> = (0..THREADS)
                .map(|_| {
                    scope.spawn(|| {
                        barrier.wait();
                        heartbeats.record_reporting_new(user, channel)
                    })
                })
                .collect();
            handles
                .into_iter()
                .map(|h| h.join().unwrap())
                .filter(|&reported_change| reported_change)
                .count()
        });

        assert_eq!(new_count, 1);
    }

    /// [`Self::forget_reporting_removed`]'s own version of the same race:
    /// many callers reporting a real hangup for an entry that only ever
    /// existed once must agree on exactly one of them being the one that
    /// removed it.
    #[test]
    fn only_one_of_many_concurrent_hangups_reports_removed() {
        let heartbeats = CallHeartbeats::new();
        let (user, channel) = (uid(), cid());
        heartbeats.record_at(user, channel, Instant::now());
        const THREADS: usize = 64;
        let barrier = std::sync::Barrier::new(THREADS);

        let removed_count: usize = std::thread::scope(|scope| {
            let handles: Vec<_> = (0..THREADS)
                .map(|_| {
                    scope.spawn(|| {
                        barrier.wait();
                        heartbeats.forget_reporting_removed(user, channel)
                    })
                })
                .collect();
            handles
                .into_iter()
                .map(|h| h.join().unwrap())
                .filter(|&reported_change| reported_change)
                .count()
        });

        assert_eq!(removed_count, 1);
    }
}
