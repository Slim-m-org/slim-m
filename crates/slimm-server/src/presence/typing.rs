// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Ephemeral, self-expiring typing state, kept in memory only. Never
//! persisted (a "someone is typing" row would outlive the typing itself by
//! construction) and never pushed to mobile: `crate::push` has no path that
//! reads anything here.
//!
//! There is no explicit "stop typing" frame; refreshing is the whole model.
//! Each accepted `typing` frame in `http::ws` bumps a per (channel, user)
//! generation counter with [`TypingTracker::start`] and schedules a delayed
//! [`TypingTracker::expire`] check. If nothing has bumped the counter again by
//! the time that check runs, the state is expired and the caller publishes a
//! `TypingStopped` event. A client refreshing faster than the TTL never sees
//! its own indicator lapse; one that vanishes mid-typing (closes, crashes,
//! loses its network) is still cleaned up by the next scheduled check, which
//! is the property that matters: nobody's screen keeps showing "is typing"
//! forever because a client went away without saying so.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use crate::ids::{ChannelId, UserId};

/// How long a typing state survives without a refresh. Long enough to
/// comfortably outlast the gap between keystrokes in ordinary typing, short
/// enough that stopping clears the indicator promptly.
pub const DEFAULT_TTL: Duration = Duration::from_secs(6);

type Key = (ChannelId, UserId);

/// A shared, cloneable handle to the in-memory typing map.
#[derive(Clone)]
pub struct TypingTracker {
    state: Arc<Mutex<HashMap<Key, u64>>>,
    ttl: Duration,
}

impl Default for TypingTracker {
    fn default() -> Self {
        Self::new()
    }
}

impl TypingTracker {
    pub fn new() -> Self {
        Self::with_ttl(DEFAULT_TTL)
    }

    /// Builds a tracker with a non-default TTL, so a test can wait it out in
    /// milliseconds instead of the production few seconds.
    pub fn with_ttl(ttl: Duration) -> Self {
        Self {
            state: Arc::new(Mutex::new(HashMap::new())),
            ttl,
        }
    }

    pub fn ttl(&self) -> Duration {
        self.ttl
    }

    /// Records a typing refresh, returning the generation this refresh owns
    /// and whether the state was not already active. A caller uses the
    /// generation to schedule the matching [`Self::expire`] check, and the
    /// `bool` to decide whether this is a fresh state worth fanning out (a
    /// mere refresh of an already-active one should not re-publish).
    pub fn start(&self, channel_id: ChannelId, user_id: UserId) -> (u64, bool) {
        let mut state = lock(&self.state);
        let key = (channel_id, user_id);
        let is_new = !state.contains_key(&key);
        let generation = state.entry(key).or_insert(0);
        *generation += 1;
        (*generation, is_new)
    }

    /// Called after this tracker's TTL has elapsed since a [`Self::start`]
    /// that returned `generation`. Returns `true` (and removes the entry) if
    /// nothing refreshed the state in the meantime, so the caller should
    /// publish `TypingStopped`. A newer refresh already bumped the generation
    /// past what this stale check is holding, so it is a no-op instead:
    /// whichever delayed check corresponds to the latest refresh is the one
    /// that will actually expire it.
    pub fn expire(&self, channel_id: ChannelId, user_id: UserId, generation: u64) -> bool {
        let mut state = lock(&self.state);
        let key = (channel_id, user_id);
        if state.get(&key) == Some(&generation) {
            state.remove(&key);
            true
        } else {
            false
        }
    }

    #[cfg(test)]
    pub fn is_typing(&self, channel_id: ChannelId, user_id: UserId) -> bool {
        lock(&self.state).contains_key(&(channel_id, user_id))
    }
}

/// A poisoned lock means another thread panicked mid-update; recover rather
/// than wedging every typing update behind a dead tracker, the same choice
/// [`crate::ratelimit::RateLimiter`] makes.
fn lock(state: &Mutex<HashMap<Key, u64>>) -> MutexGuard<'_, HashMap<Key, u64>> {
    match state.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ids() -> (ChannelId, UserId) {
        (ChannelId::generate(), UserId::generate())
    }

    #[test]
    fn first_start_is_new_a_refresh_is_not() {
        let tracker = TypingTracker::new();
        let (channel, user) = ids();

        let (gen1, is_new1) = tracker.start(channel, user);
        assert!(is_new1);
        let (gen2, is_new2) = tracker.start(channel, user);
        assert!(!is_new2, "refreshing an active state is not a fresh start");
        assert!(gen2 > gen1, "each refresh still advances the generation");
    }

    #[test]
    fn expire_matches_only_the_latest_generation() {
        let tracker = TypingTracker::new();
        let (channel, user) = ids();

        let (gen1, _) = tracker.start(channel, user);
        let (gen2, _) = tracker.start(channel, user);
        assert_ne!(gen1, gen2);

        // A stale check for the first generation is a no-op: a refresh
        // happened since, so the state must not be torn down under it.
        assert!(!tracker.expire(channel, user, gen1));
        assert!(tracker.is_typing(channel, user));

        // The check for the latest generation actually expires it.
        assert!(tracker.expire(channel, user, gen2));
        assert!(!tracker.is_typing(channel, user));
    }

    #[test]
    fn expire_is_idempotent_once_it_has_already_fired() {
        let tracker = TypingTracker::new();
        let (channel, user) = ids();
        let (generation, _) = tracker.start(channel, user);
        assert!(tracker.expire(channel, user, generation));
        assert!(!tracker.expire(channel, user, generation));
    }

    #[test]
    fn distinct_channels_and_users_do_not_interfere() {
        let tracker = TypingTracker::new();
        let (channel_a, alice) = ids();
        let (channel_b, bob) = ids();

        tracker.start(channel_a, alice);
        assert!(tracker.is_typing(channel_a, alice));
        assert!(!tracker.is_typing(channel_b, alice));
        assert!(!tracker.is_typing(channel_a, bob));

        tracker.start(channel_b, bob);
        assert!(tracker.is_typing(channel_b, bob));
    }
}
