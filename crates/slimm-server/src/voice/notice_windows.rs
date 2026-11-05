// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The once-per-ten-minutes limit on voice activity notices (decision 0107).
//!
//! Ephemeral and keyed on the channel and the recipient, so one person's quiet window never
//! silences another's, and a restart forgetting it costs at most one extra notice.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard};

use crate::ids::{ChannelId, UserId};

/// How long a recipient hears nothing more about a channel once told.
pub const NOTICE_WINDOW_MS: i64 = 10 * 60 * 1000;

/// Past this many windows, lapsed ones are swept on the next claim.
const PRUNE_ABOVE: usize = 4_096;

#[derive(Clone, Default)]
pub struct NoticeWindows {
    opened: Arc<Mutex<HashMap<(ChannelId, UserId), i64>>>,
}

impl NoticeWindows {
    fn lock(&self) -> MutexGuard<'_, HashMap<(ChannelId, UserId), i64>> {
        self.opened
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// Opens the window for `user` in `channel` at `now`, or `None` while one is still open.
    /// The returned stamp is what [`Self::release`] needs if nobody was actually told.
    pub fn claim(&self, channel: ChannelId, user: UserId, now: i64) -> Option<i64> {
        let mut opened = self.lock();
        if opened
            .get(&(channel, user))
            .is_some_and(|at| now - *at < NOTICE_WINDOW_MS)
        {
            return None;
        }
        if opened.len() >= PRUNE_ABOVE {
            opened.retain(|_, at| now - *at < NOTICE_WINDOW_MS);
        }
        opened.insert((channel, user), now);
        Some(now)
    }

    /// Gives back a window that told nobody, unless a later claim has reopened it since.
    pub fn release(&self, channel: ChannelId, user: UserId, claimed_at: i64) {
        let mut opened = self.lock();
        if opened.get(&(channel, user)) == Some(&claimed_at) {
            opened.remove(&(channel, user));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_second_claim_inside_the_window_is_refused_then_reopens() {
        let windows = NoticeWindows::default();
        let (channel, user) = (ChannelId::generate(), UserId::generate());
        assert!(windows.claim(channel, user, 0).is_some());
        assert!(windows.claim(channel, user, NOTICE_WINDOW_MS - 1).is_none());
        assert!(windows.claim(channel, user, NOTICE_WINDOW_MS).is_some());
    }

    #[test]
    fn windows_are_per_channel_and_per_recipient() {
        let windows = NoticeWindows::default();
        let (a, b) = (ChannelId::generate(), ChannelId::generate());
        let (alice, bob) = (UserId::generate(), UserId::generate());
        assert!(windows.claim(a, alice, 0).is_some());
        assert!(windows.claim(a, bob, 1).is_some());
        assert!(windows.claim(b, alice, 1).is_some());
    }

    #[test]
    fn a_released_window_reopens_but_never_a_newer_one() {
        let windows = NoticeWindows::default();
        let (channel, user) = (ChannelId::generate(), UserId::generate());
        let first = windows.claim(channel, user, 0).expect("opens");
        windows.release(channel, user, first);
        let second = windows
            .claim(channel, user, 1)
            .expect("reopens after release");
        windows.release(channel, user, first);
        assert!(
            windows.claim(channel, user, 2).is_none(),
            "stale release is a no-op"
        );
        windows.release(channel, user, second);
        assert!(windows.claim(channel, user, 3).is_some());
    }
}
