// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Coalesces the "re-read this roster" nudge per channel: the first goes out at once, and any
//! more inside the window collapse into one trailing nudge, so mute toggling cannot make every
//! viewer refetch the roster more than about twice a second.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::time::Instant;

use super::{Event, Hub};
use crate::ids::ChannelId;

/// Shortest gap between two roster nudges for one channel.
pub(super) const NUDGE_WINDOW: Duration = Duration::from_millis(500);

#[derive(Clone, Default)]
pub(super) struct VoiceNudges {
    channels: Arc<Mutex<HashMap<ChannelId, Cooling>>>,
}

struct Cooling {
    sent_at: Instant,
    trailing_queued: bool,
}

enum Verdict {
    SendNow,
    SendAt(Instant),
    Drop,
}

impl VoiceNudges {
    fn admit(&self, channel_id: ChannelId) -> Verdict {
        let now = Instant::now();
        let mut channels = self
            .channels
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        channels.retain(|_, c| c.trailing_queued || now.duration_since(c.sent_at) < NUDGE_WINDOW);
        match channels.get_mut(&channel_id) {
            None => {
                channels.insert(
                    channel_id,
                    Cooling {
                        sent_at: now,
                        trailing_queued: false,
                    },
                );
                Verdict::SendNow
            }
            Some(cooling) if cooling.trailing_queued => Verdict::Drop,
            Some(cooling) => {
                cooling.trailing_queued = true;
                Verdict::SendAt(cooling.sent_at + NUDGE_WINDOW)
            }
        }
    }

    fn sent(&self, channel_id: ChannelId) {
        let mut channels = self
            .channels
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        channels.insert(
            channel_id,
            Cooling {
                sent_at: Instant::now(),
                trailing_queued: false,
            },
        );
    }
}

impl Hub {
    /// Publishes [`Event::VoiceActivityChanged`] for the channel, at most once per
    /// [`NUDGE_WINDOW`] with the last request in a burst delivered on the trailing edge.
    pub fn nudge_voice_roster(&self, channel_id: ChannelId) {
        match self.voice_nudges.admit(channel_id) {
            Verdict::SendNow => self.publish(Event::VoiceActivityChanged { channel_id }),
            Verdict::Drop => {}
            Verdict::SendAt(at) => {
                let hub = self.clone();
                tokio::spawn(async move {
                    tokio::time::sleep_until(at).await;
                    hub.voice_nudges.sent(channel_id);
                    hub.publish(Event::VoiceActivityChanged { channel_id });
                });
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn drain(rx: &mut tokio::sync::broadcast::Receiver<Event>) -> usize {
        let mut n = 0;
        while rx.try_recv().is_ok() {
            n += 1;
        }
        n
    }

    #[tokio::test(start_paused = true)]
    async fn a_burst_becomes_a_leading_and_one_trailing_nudge() {
        let hub = Hub::new();
        let mut rx = hub.subscribe();
        let channel = ChannelId::generate();
        for _ in 0..50 {
            hub.nudge_voice_roster(channel);
        }
        assert_eq!(drain(&mut rx), 1);
        tokio::time::sleep(NUDGE_WINDOW + Duration::from_millis(10)).await;
        assert_eq!(drain(&mut rx), 1);
        tokio::time::sleep(NUDGE_WINDOW * 3).await;
        assert_eq!(drain(&mut rx), 0);
    }

    #[tokio::test(start_paused = true)]
    async fn sustained_toggling_stays_near_two_a_second() {
        let hub = Hub::new();
        let mut rx = hub.subscribe();
        let channel = ChannelId::generate();
        for _ in 0..100 {
            hub.nudge_voice_roster(channel);
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        tokio::time::sleep(NUDGE_WINDOW * 2).await;
        let sent = drain(&mut rx);
        assert!((3..=5).contains(&sent), "{sent} nudges in 2s");
    }

    #[tokio::test(start_paused = true)]
    async fn channels_are_coalesced_independently() {
        let hub = Hub::new();
        let mut rx = hub.subscribe();
        hub.nudge_voice_roster(ChannelId::generate());
        hub.nudge_voice_roster(ChannelId::generate());
        assert_eq!(drain(&mut rx), 2);
    }
}
