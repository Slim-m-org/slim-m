// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! One connection's cached permission sets per channel, so delivering an
//! event does not re-run five queries. An entry is reused only while the
//! hub's permissions epoch it was taken at stands, with a TTL as backstop
//! for writes that publish nothing; errors are never cached. Why it is
//! keyed on the epoch and not on events is in docs/internals.md.

use std::collections::HashMap;
use std::time::{Duration, Instant};

use crate::ids::{CanvasObjectId, ChannelId};
use crate::permissions::Permissions;

/// How long an answer may be reused before it is asked again.
///
/// Short enough that a permission write nothing published is a blink rather
/// than a session, and long enough that a channel taking several messages a
/// second still asks once rather than once per message.
pub(super) const TTL: Duration = Duration::from_secs(5);

/// Most channels one connection caches; frames naming random channel ids would otherwise grow it forever.
const MAX_CHANNELS: usize = 256;
/// Most objects one connection remembers as previewable at once.
const MAX_PREVIEWABLE: usize = 64;

/// One connection's cached per-channel permission sets.
pub(super) struct PermissionCache {
    entries: HashMap<ChannelId, Entry>,
    timeout: Option<TimeoutEntry>,
    previewable: HashMap<(ChannelId, CanvasObjectId), Instant>,
}

/// The member's timeout expiry as last read, kept as an instant rather than a
/// flag so a timeout that runs out is honoured without a fresh read.
struct TimeoutEntry {
    until_ms: Option<i64>,
    asked_at: Instant,
    epoch: u64,
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
            timeout: None,
            previewable: HashMap::new(),
        }
    }

    /// Whether the member was just found able to move this object, so a drag's
    /// stream of previews asks the store once rather than once per frame.
    pub(super) fn previewable(
        &self,
        channel_id: ChannelId,
        object_id: CanvasObjectId,
        now: Instant,
    ) -> bool {
        self.previewable
            .get(&(channel_id, object_id))
            .is_some_and(|asked_at| now.duration_since(*asked_at) < TTL)
    }

    pub(super) fn insert_previewable(
        &mut self,
        channel_id: ChannelId,
        object_id: CanvasObjectId,
        now: Instant,
    ) {
        if self.previewable.len() >= MAX_PREVIEWABLE {
            self.previewable
                .retain(|_, asked_at| now.duration_since(*asked_at) < TTL);
        }
        if self.previewable.len() >= MAX_PREVIEWABLE {
            self.previewable.clear();
        }
        self.previewable.insert((channel_id, object_id), now);
    }

    /// The cached timeout expiry (`Some(None)` is a cached "not timed out"), or `None` to go and ask.
    pub(super) fn timeout_until(&self, now: Instant, epoch: u64) -> Option<Option<i64>> {
        let entry = self.timeout.as_ref()?;
        let fresh = now.duration_since(entry.asked_at) < TTL && entry.epoch == epoch;
        fresh.then_some(entry.until_ms)
    }

    /// Records a timeout answer; the epoch must have been read before the query, as for [`Self::insert`].
    pub(super) fn insert_timeout(&mut self, until_ms: Option<i64>, now: Instant, epoch: u64) {
        self.timeout = Some(TimeoutEntry {
            until_ms,
            asked_at: now,
            epoch,
        });
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
        if self.entries.len() >= MAX_CHANNELS && !self.entries.contains_key(&channel_id) {
            self.entries
                .retain(|_, entry| now.duration_since(entry.asked_at) < TTL);
            if self.entries.len() >= MAX_CHANNELS {
                self.entries.clear();
            }
        }
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
    fn a_timeout_answer_follows_the_same_epoch_and_window() {
        let (mut cache, _, now) = cache();
        assert_eq!(cache.timeout_until(now, 7), None);
        cache.insert_timeout(Some(5), now, 7);
        assert_eq!(cache.timeout_until(now, 7), Some(Some(5)));
        assert_eq!(cache.timeout_until(now, 8), None);
        assert_eq!(cache.timeout_until(now + TTL, 7), None);
    }

    #[test]
    fn the_cache_never_holds_more_than_its_cap_of_channels() {
        let (mut cache, _, now) = cache();
        for _ in 0..(MAX_CHANNELS * 3) {
            cache.insert(ChannelId::generate(), VIEW, now, 7);
        }
        assert!(cache.entries.len() <= MAX_CHANNELS);
    }

    #[test]
    fn a_previewable_object_is_remembered_for_the_window_only() {
        let (mut cache, channel, now) = cache();
        let object = CanvasObjectId::generate();
        assert!(!cache.previewable(channel, object, now));
        cache.insert_previewable(channel, object, now);
        assert!(cache.previewable(channel, object, now));
        assert!(!cache.previewable(channel, object, now + TTL));
    }

    #[test]
    fn an_unknown_channel_is_never_a_hit() {
        let (cache, channel, now) = cache();
        assert_eq!(cache.get(channel, now, 0), None);
    }
}
