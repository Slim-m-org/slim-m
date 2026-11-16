// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Each sharer's last relayed drawing consent, so the stamp route can refuse a stamp
//! the sharer's screen would drop (decision 0121).

use std::collections::HashMap;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, Instant};

use crate::ids::{ChannelId, UserId};

/// How long a consent frame is believed; the sharer repeats it every 5 seconds.
pub const CONSENT_BELIEVED_FOR: Duration = Duration::from_secs(15);

#[derive(Debug, Clone, Copy)]
struct Seen {
    allowed: bool,
    stamps: bool,
    at: Instant,
}

/// Consent by (channel, sharer). Empty after a restart until the next heartbeat.
#[derive(Clone, Default)]
pub struct ScreenConsent {
    seen: Arc<Mutex<HashMap<(ChannelId, UserId), Seen>>>,
}

impl ScreenConsent {
    /// Records a relayed consent frame, dropping every entry no longer believed.
    pub fn record(
        &self,
        channel_id: ChannelId,
        sharer: UserId,
        (allowed, stamps): (bool, bool),
        now: Instant,
    ) {
        let mut seen = self.seen.lock().unwrap_or_else(PoisonError::into_inner);
        seen.retain(|_, s| believed(s, now));
        seen.insert(
            (channel_id, sharer),
            Seen {
                allowed,
                stamps,
                at: now,
            },
        );
    }

    /// Whether `sharer` said, recently enough, that viewers may draw and their screen shows stamps.
    pub fn live_for_stamps(&self, channel_id: ChannelId, sharer: UserId, now: Instant) -> bool {
        let mut seen = self.seen.lock().unwrap_or_else(PoisonError::into_inner);
        let key = (channel_id, sharer);
        match seen.get(&key).copied() {
            Some(s) if believed(&s, now) => s.allowed && s.stamps,
            Some(_) => {
                seen.remove(&key);
                false
            }
            None => false,
        }
    }
}

fn believed(seen: &Seen, now: Instant) -> bool {
    now.saturating_duration_since(seen.at) <= CONSENT_BELIEVED_FOR
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ids() -> (ChannelId, UserId) {
        (
            ChannelId(uuid::Uuid::now_v7()),
            UserId(uuid::Uuid::now_v7()),
        )
    }

    #[test]
    fn nothing_recorded_takes_no_stamps() {
        let (channel, sharer) = ids();
        assert!(!ScreenConsent::default().live_for_stamps(channel, sharer, Instant::now()));
    }

    #[test]
    fn consent_needs_both_allowed_and_stamps() {
        let (channel, sharer) = ids();
        let consent = ScreenConsent::default();
        let now = Instant::now();
        consent.record(channel, sharer, (true, false), now);
        assert!(!consent.live_for_stamps(channel, sharer, now));
        consent.record(channel, sharer, (false, true), now);
        assert!(!consent.live_for_stamps(channel, sharer, now));
        consent.record(channel, sharer, (true, true), now);
        assert!(consent.live_for_stamps(channel, sharer, now));
    }

    #[test]
    fn consent_lapses_fifteen_seconds_after_the_last_frame() {
        let (channel, sharer) = ids();
        let consent = ScreenConsent::default();
        let start = Instant::now();
        consent.record(channel, sharer, (true, true), start);
        assert!(consent.live_for_stamps(channel, sharer, start + CONSENT_BELIEVED_FOR));
        let late = start + CONSENT_BELIEVED_FOR + Duration::from_millis(1);
        assert!(!consent.live_for_stamps(channel, sharer, late));
    }

    #[test]
    fn consent_is_kept_per_channel_and_per_sharer() {
        let (channel, sharer) = ids();
        let (other_channel, other_sharer) = ids();
        let consent = ScreenConsent::default();
        let now = Instant::now();
        consent.record(channel, sharer, (true, true), now);
        assert!(!consent.live_for_stamps(other_channel, sharer, now));
        assert!(!consent.live_for_stamps(channel, other_sharer, now));
    }

    #[test]
    fn recording_drops_entries_no_longer_believed() {
        let (channel, sharer) = ids();
        let (other_channel, other_sharer) = ids();
        let consent = ScreenConsent::default();
        let start = Instant::now();
        consent.record(channel, sharer, (true, true), start);
        let later = start + CONSENT_BELIEVED_FOR * 2;
        consent.record(other_channel, other_sharer, (true, true), later);
        assert_eq!(consent.seen.lock().unwrap().len(), 1);
    }
}
