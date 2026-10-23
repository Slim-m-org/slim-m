// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A short memory of what modules returned for a slot, so a profile opened
//! twice or a member list scrolled past does not run a module each time.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use super::module_slot_nodes::SlotItem;
use crate::ids::UserId;

const TTL: Duration = Duration::from_secs(30);
const MAX_ENTRIES: usize = 20_000;

/// Includes the viewer because a module sees `viewer_id` and may answer per viewer.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub(crate) struct SlotKey {
    pub(crate) module_id: String,
    pub(crate) artifact_sha256: String,
    pub(crate) kind: String,
    pub(crate) name: String,
    pub(crate) viewer: UserId,
    pub(crate) member: UserId,
}

type Entries = HashMap<SlotKey, (Instant, Option<SlotItem>)>;

#[derive(Clone, Default)]
pub struct SlotCache {
    entries: Arc<Mutex<Entries>>,
}

impl SlotCache {
    /// `Some(None)` is a cached "nothing to show"; `None` is a miss.
    pub(crate) fn get(&self, key: &SlotKey, now: Instant) -> Option<Option<SlotItem>> {
        let entries = self.entries.lock().ok()?;
        let (at, item) = entries.get(key)?;
        (now.saturating_duration_since(*at) < TTL).then(|| item.clone())
    }

    pub(crate) fn put(&self, key: SlotKey, item: Option<SlotItem>, now: Instant) {
        let Ok(mut entries) = self.entries.lock() else {
            return;
        };
        if entries.len() >= MAX_ENTRIES {
            entries.retain(|_, (at, _)| now.saturating_duration_since(*at) < TTL);
        }
        if entries.len() < MAX_ENTRIES {
            entries.insert(key, (now, item));
        }
    }

    /// Dropped when a module is disabled, updated or uninstalled.
    pub(crate) fn invalidate_module(&self, module_id: &str) {
        if let Ok(mut entries) = self.entries.lock() {
            entries.retain(|key, _| key.module_id != module_id);
        }
    }

    #[cfg(test)]
    fn len(&self) -> usize {
        self.entries.lock().map_or(0, |e| e.len())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key(module: &str, member: UserId) -> SlotKey {
        SlotKey {
            module_id: module.into(),
            artifact_sha256: "sha".into(),
            kind: "member.badge".into(),
            name: "level".into(),
            viewer: UserId::generate(),
            member,
        }
    }

    #[test]
    fn an_entry_lives_thirty_seconds_and_a_miss_is_not_a_cached_nothing() {
        let cache = SlotCache::default();
        let k = key("xp", UserId::generate());
        let t0 = Instant::now();
        assert_eq!(cache.get(&k, t0), None);
        cache.put(k.clone(), None, t0);
        assert_eq!(cache.get(&k, t0 + Duration::from_secs(29)), Some(None));
        assert_eq!(cache.get(&k, t0 + Duration::from_secs(30)), None);
    }

    #[test]
    fn invalidating_a_module_leaves_the_others() {
        let cache = SlotCache::default();
        let (xp, other) = (
            key("xp", UserId::generate()),
            key("other", UserId::generate()),
        );
        let now = Instant::now();
        cache.put(xp.clone(), None, now);
        cache.put(other.clone(), None, now);
        cache.invalidate_module("xp");
        assert_eq!(cache.get(&xp, now), None);
        assert_eq!(cache.get(&other, now), Some(None));
    }

    #[test]
    fn the_cache_is_bounded_and_makes_room_by_dropping_expired_entries() {
        let cache = SlotCache::default();
        let t0 = Instant::now();
        for _ in 0..MAX_ENTRIES {
            cache.put(key("xp", UserId::generate()), None, t0);
        }
        cache.put(key("xp", UserId::generate()), None, t0);
        assert_eq!(cache.len(), MAX_ENTRIES, "full and fresh: not stored");
        let later = t0 + Duration::from_secs(31);
        cache.put(key("xp", UserId::generate()), None, later);
        assert_eq!(cache.len(), 1, "expired entries made room");
    }
}
