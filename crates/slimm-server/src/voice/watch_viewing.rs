// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Which members of a call are playing the watch party's title themselves.
//!
//! Ephemeral and keyed on the channel and the member: a viewer restates it every few seconds, and a
//! report that stops arriving reads as "on the shared track", so a crashed or departed client can
//! never leave the bot believing nobody needs its stream. See
//! docs/decisions/0050-watch-party-sync-authority-and-direct-play.md.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use crate::ids::{ChannelId, UserId};

/// A report older than this no longer counts; viewers restate well inside it.
pub const VIEWING_TTL: Duration = Duration::from_secs(20);

#[derive(Clone, Default)]
pub struct WatchViewing {
    state: Arc<Mutex<HashMap<(ChannelId, UserId), Instant>>>,
}

impl WatchViewing {
    fn lock(&self) -> MutexGuard<'_, HashMap<(ChannelId, UserId), Instant>> {
        self.state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// Records that `user` is (or, when `direct` is false, stopped) playing the title themselves.
    pub fn report_at(&self, channel: ChannelId, user: UserId, direct: bool, now: Instant) {
        let mut state = self.lock();
        state.retain(|_, at| now.saturating_duration_since(*at) <= VIEWING_TTL);
        if direct {
            state.insert((channel, user), now);
        } else {
            state.remove(&(channel, user));
        }
    }

    /// Everyone in `channel` whose latest report says direct and has not lapsed.
    pub fn direct_viewers_at(&self, channel: ChannelId, now: Instant) -> Vec<UserId> {
        let mut viewers: Vec<UserId> = self
            .lock()
            .iter()
            .filter(|((c, _), at)| {
                *c == channel && now.saturating_duration_since(**at) <= VIEWING_TTL
            })
            .map(|((_, user), _)| *user)
            .collect();
        viewers.sort_by_key(ToString::to_string);
        viewers
    }

    /// Forgets a channel's reports, for a session that ended.
    pub fn clear(&self, channel: ChannelId) {
        self.lock().retain(|(c, _), _| *c != channel);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ids() -> (ChannelId, UserId, UserId) {
        (
            ChannelId(uuid::Uuid::now_v7()),
            UserId(uuid::Uuid::now_v7()),
            UserId(uuid::Uuid::now_v7()),
        )
    }

    #[test]
    fn a_report_counts_until_it_lapses_and_a_retraction_removes_it() {
        let (ch, a, b) = ids();
        let v = WatchViewing::default();
        let t0 = Instant::now();
        v.report_at(ch, a, true, t0);
        v.report_at(ch, b, true, t0);
        assert_eq!(v.direct_viewers_at(ch, t0).len(), 2);
        v.report_at(ch, b, false, t0);
        assert_eq!(v.direct_viewers_at(ch, t0), vec![a]);
        assert!(
            v.direct_viewers_at(ch, t0 + VIEWING_TTL + Duration::from_secs(1))
                .is_empty()
        );
    }

    #[test]
    fn reports_are_per_channel_and_clear_drops_one_channel() {
        let (ch, a, _) = ids();
        let other = ChannelId(uuid::Uuid::now_v7());
        let v = WatchViewing::default();
        let t0 = Instant::now();
        v.report_at(ch, a, true, t0);
        v.report_at(other, a, true, t0);
        v.clear(ch);
        assert!(v.direct_viewers_at(ch, t0).is_empty());
        assert_eq!(v.direct_viewers_at(other, t0), vec![a]);
    }
}
