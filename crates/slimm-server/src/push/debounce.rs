// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Collapsing a burst of messages into one wake per recipient.
//!
//! Split out of [`super`] because it is a self-contained decision with its own
//! invariant - a window may only stay shut when somebody was really woken -
//! and because that invariant is worth testing without a store, a relay, or an
//! HTTP stack anywhere near it. [`super::deliver::deliver`] is the only caller.

use std::collections::HashMap;
use std::sync::Mutex;

use crate::ids::{ChannelId, UserId};
use crate::store::now_ms;

/// Collapses a burst of triggers into one per `(channel, recipient)`.
/// Leading-edge: the first trigger after a window last elapsed, or was
/// released (see [`Self::release_if_undelivered`]), opens the window and
/// records `now`; every other trigger for that same pair inside the window is
/// suppressed.
///
/// Keyed on the pair, not the channel alone: one recipient's suppressed
/// window must never silence a different recipient's wake. Debouncing exists
/// to collapse a burst of messages for one person, not to let one recipient's
/// state (or bad luck) silence somebody else's notification.
///
/// A mention is not collapsed into a window a plain message opened: it is the
/// one push a recipient asked for by name, so it reopens the window as a
/// mention window instead.
pub(super) struct Debounce {
    window_ms: i64,
    last_fired: Mutex<HashMap<(ChannelId, UserId), Window>>,
}

#[derive(Clone, Copy)]
struct Window {
    opened_at: i64,
    by_mention: bool,
}

/// Past this many open windows, elapsed ones are swept on the next insert, so
/// the map tracks recent pairs rather than every pair ever pushed.
const PRUNE_ABOVE: usize = 4_096;

impl Debounce {
    pub(super) fn new(window_ms: i64) -> Self {
        Self {
            window_ms,
            last_fired: Mutex::new(HashMap::new()),
        }
    }

    /// Attempts to open a window for `(channel_id, user_id)`. `Some(fired_at)`
    /// means this trigger is not suppressed and the caller now owns the
    /// window: if it turns out nobody was actually notified, it must call
    /// [`Self::release_if_undelivered`] with the same `fired_at`, or the next
    /// genuine trigger for this recipient would be wrongly suppressed too.
    /// `None` means a burst is already collapsed into an open window.
    pub(super) fn try_fire(
        &self,
        channel_id: ChannelId,
        user_id: UserId,
        mention: bool,
    ) -> Option<i64> {
        self.try_fire_at(channel_id, user_id, now_ms(), mention)
    }

    /// [`Self::try_fire`] with an explicit clock, for deterministic tests.
    pub(super) fn try_fire_at(
        &self,
        channel_id: ChannelId,
        user_id: UserId,
        now: i64,
        mention: bool,
    ) -> Option<i64> {
        let mut last_fired = self.lock();
        let key = (channel_id, user_id);
        let suppressed = last_fired.get(&key).is_some_and(|window| {
            now - window.opened_at < self.window_ms && (window.by_mention || !mention)
        });
        if suppressed {
            return None;
        }
        if last_fired.len() >= PRUNE_ABOVE {
            last_fired.retain(|_, window| now - window.opened_at < self.window_ms);
        }
        last_fired.insert(
            key,
            Window {
                opened_at: now,
                by_mention: mention,
            },
        );
        Some(now)
    }

    /// Releases a window that turned out to deliver nobody anything, so the
    /// next trigger for this recipient is not suppressed by a burst whose
    /// leading edge failed. A no-op if the window has already moved on (it
    /// elapsed naturally and was re-opened by a later, successful trigger)
    /// since `fired_at`, so a late release from a slow delivery task can never
    /// claw back a newer window.
    pub(super) fn release_if_undelivered(
        &self,
        channel_id: ChannelId,
        user_id: UserId,
        fired_at: i64,
    ) {
        let mut last_fired = self.lock();
        let key = (channel_id, user_id);
        if last_fired.get(&key).map(|window| window.opened_at) == Some(fired_at) {
            last_fired.remove(&key);
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<(ChannelId, UserId), Window>> {
        match self.last_fired.lock() {
            Ok(guard) => guard,
            Err(poisoned) => poisoned.into_inner(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn user() -> UserId {
        UserId::generate()
    }

    #[test]
    fn debounce_collapses_a_burst_then_reopens() {
        let debounce = Debounce::new(1_000);
        let channel = ChannelId::generate();
        let bob = user();
        assert!(
            debounce.try_fire_at(channel, bob, 0, false).is_some(),
            "first trigger fires"
        );
        assert!(
            debounce.try_fire_at(channel, bob, 500, false).is_none(),
            "inside the window is suppressed"
        );
        assert!(
            debounce.try_fire_at(channel, bob, 999, false).is_none(),
            "still inside the window"
        );
        assert!(
            debounce.try_fire_at(channel, bob, 1_000, false).is_some(),
            "the window has fully elapsed"
        );
    }

    #[test]
    fn debounce_is_independent_per_channel() {
        let debounce = Debounce::new(1_000);
        let a = ChannelId::generate();
        let b = ChannelId::generate();
        let bob = user();
        assert!(debounce.try_fire_at(a, bob, 0, false).is_some());
        // A burst in channel a does not suppress channel b.
        assert!(debounce.try_fire_at(b, bob, 0, false).is_some());
        assert!(debounce.try_fire_at(a, bob, 100, false).is_none());
    }

    /// Regression: the debounce used to be keyed on channel alone, so a window
    /// opened by one recipient's message silenced every other recipient in the
    /// same channel for the rest of that window.
    #[test]
    fn debounce_is_independent_per_recipient() {
        let debounce = Debounce::new(1_000);
        let channel = ChannelId::generate();
        let bob = user();
        let carol = user();
        assert!(debounce.try_fire_at(channel, bob, 0, false).is_some());
        assert!(
            debounce.try_fire_at(channel, carol, 50, false).is_some(),
            "bob's open window must not suppress carol's wake"
        );
        assert!(
            debounce.try_fire_at(channel, bob, 100, false).is_none(),
            "bob's own burst is still collapsed"
        );
    }

    /// Regression: a leading trigger that ends up delivering nobody anything
    /// (a relay error, or every device filtered out) used to spend the window
    /// regardless, dropping the next message's wake outright instead of merely
    /// collapsing it.
    #[test]
    fn release_if_undelivered_reopens_the_window_immediately() {
        let debounce = Debounce::new(1_000);
        let channel = ChannelId::generate();
        let bob = user();
        let fired_at = debounce
            .try_fire_at(channel, bob, 0, false)
            .expect("first trigger fires");
        debounce.release_if_undelivered(channel, bob, fired_at);
        assert!(
            debounce.try_fire_at(channel, bob, 1, false).is_some(),
            "a window that delivered nothing must not suppress the very next trigger"
        );
    }

    #[test]
    fn release_if_undelivered_does_not_clobber_a_newer_window() {
        let debounce = Debounce::new(1_000);
        let channel = ChannelId::generate();
        let bob = user();
        let stale_fired_at = debounce.try_fire_at(channel, bob, 0, false).unwrap();
        // The window elapses naturally and opens again for a later message.
        assert!(debounce.try_fire_at(channel, bob, 1_000, false).is_some());
        // A late release from the first task must not tear the second down.
        debounce.release_if_undelivered(channel, bob, stale_fired_at);
        assert!(
            debounce.try_fire_at(channel, bob, 1_500, false).is_none(),
            "the newer window must still be in effect"
        );
    }

    #[test]
    fn a_mention_is_not_collapsed_into_a_plain_message_window() {
        let debounce = Debounce::new(10_000);
        let (channel, bob) = (ChannelId::generate(), user());
        assert!(debounce.try_fire_at(channel, bob, 0, false).is_some());
        assert!(
            debounce.try_fire_at(channel, bob, 5_000, true).is_some(),
            "the mention was dropped by the plain-message window"
        );
        assert!(debounce.try_fire_at(channel, bob, 6_000, true).is_none());
        assert!(debounce.try_fire_at(channel, bob, 7_000, false).is_none());
    }

    #[test]
    fn elapsed_windows_are_swept_once_the_map_grows() {
        let debounce = Debounce::new(1_000);
        let channel = ChannelId::generate();
        for _ in 0..PRUNE_ABOVE {
            debounce.try_fire_at(channel, user(), 0, false);
        }
        debounce.try_fire_at(channel, user(), 5_000, false);
        assert_eq!(
            debounce.lock().len(),
            1,
            "elapsed windows were kept forever"
        );
    }
}
