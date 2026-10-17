// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! One connection's cached permission sets per channel, so delivering an
//! event does not re-run five queries. An entry is reused only while the
//! hub's permissions epoch it was taken at stands, with a TTL as backstop
//! for writes that publish nothing; errors are never cached. Why it is
//! keyed on the epoch and not on events is in docs/internals.md.

use std::collections::HashMap;
use std::time::{Duration, Instant};

use crate::ids::ChannelId;
use crate::permissions::Permissions;

/// How long an answer may be reused before it is asked again.
///
/// Short enough that a permission write nothing published is a blink rather
/// than a session, and long enough that a channel taking several messages a
/// second still asks once rather than once per message.
pub(super) const TTL: Duration = Duration::from_secs(5);

/// One connection's cached per-channel permission sets.
pub(super) struct PermissionCache {
    entries: HashMap<ChannelId, Entry>,
}

struct Entry {
    permissions: Permissions,
    asked_at: Instant,
    epoch: u64,
}

impl PermissionCache {
    pub(super) fn new() -> Self {
        Self {
            entries: HashMap::new(),
        }
    }

    /// The cached answer for `channel_id`, or `None` to go and ask.
    ///
    /// Both conditions are necessary: `epoch` catches a permission change that
    /// was published, however the events happen to interleave, and `now`
    /// catches one that was not.
    pub(super) fn get(
        &self,
        channel_id: ChannelId,
        now: Instant,
        epoch: u64,
    ) -> Option<Permissions> {
        let entry = self.entries.get(&channel_id)?;
        let fresh = now.duration_since(entry.asked_at) < TTL && entry.epoch == epoch;
        fresh.then_some(entry.permissions)
    }

    /// Records an answer against the epoch it was derived under.
    ///
    /// The caller must read the epoch *before* asking the store, not after: an
    /// epoch read afterwards could belong to a write that landed during the
    /// query, and the answer would be filed as newer than it is.
    pub(super) fn insert(
        &mut self,
        channel_id: ChannelId,
        permissions: Permissions,
        now: Instant,
        epoch: u64,
    ) {
        self.entries.insert(
            channel_id,
            Entry {
                permissions,
                asked_at: now,
                epoch,
            },
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cache() -> (PermissionCache, ChannelId, Instant) {
        (
            PermissionCache::new(),
            ChannelId::generate(),
            Instant::now(),
        )
    }

    const VIEW: Permissions = Permissions::VIEW_CHANNEL;

    /// Without this the struct could return `None` forever and every
    /// invalidation test below would still pass while nothing was cached.
    #[test]
    fn an_answer_is_reused_inside_the_window() {
        let (mut cache, channel, now) = cache();
        cache.insert(channel, VIEW, now, 7);
        assert_eq!(cache.get(channel, now, 7), Some(VIEW));
        assert_eq!(
            cache.get(channel, now + TTL - Duration::from_millis(1), 7),
            Some(VIEW)
        );
    }

    #[test]
    fn an_answer_expires_on_its_own() {
        let (mut cache, channel, now) = cache();
        cache.insert(channel, VIEW, now, 7);
        assert_eq!(cache.get(channel, now + TTL, 7), None);
    }

    /// The load-bearing one: a permission write moves the epoch, and that
    /// alone drops the answer with no event having been received.
    #[test]
    fn a_moved_epoch_drops_the_answer_immediately() {
        let (mut cache, channel, now) = cache();
        cache.insert(channel, VIEW, now, 7);
        assert_eq!(cache.get(channel, now, 8), None);
    }

    /// An epoch that moved and moved back is still a different answer: the
    /// counter only ever climbs, so this can only mean two writes happened.
    #[test]
    fn every_channel_answers_to_the_same_epoch() {
        let (mut cache, channel, now) = cache();
        let other = ChannelId::generate();
        cache.insert(channel, VIEW, now, 7);
        cache.insert(other, Permissions::NONE, now, 7);
        assert_eq!(cache.get(channel, now, 8), None);
        assert_eq!(cache.get(other, now, 8), None);
    }

    #[test]
    fn an_unknown_channel_is_never_a_hit() {
        let (cache, channel, now) = cache();
        assert_eq!(cache.get(channel, now, 0), None);
    }
}
