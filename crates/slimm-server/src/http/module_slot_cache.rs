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
/// How long a second fill waits for the viewer's running one before giving up.
pub(crate) const FILL_WAIT: Duration = Duration::from_secs(2);

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

#[derive(Default)]
struct Inner {
    entries: HashMap<SlotKey, (Instant, Option<SlotItem>)>,
    /// Bumped on every invalidation, so a run that began before one cannot store its answer after it.
    generations: HashMap<String, u64>,
    /// One lock per viewer with a slot fill in flight or waiting; one at a time keeps a member from filling the lane.
    filling: HashMap<UserId, Arc<tokio::sync::Mutex<()>>>,
}

#[derive(Clone, Default)]
pub struct SlotCache {
    inner: Arc<Mutex<Inner>>,
}

/// Holds a viewer's place as the one with a slot fill in flight, until dropped.
pub(crate) struct ViewerFill {
    cache: SlotCache,
    viewer: UserId,
    guard: Option<tokio::sync::OwnedMutexGuard<()>>,
}

impl Drop for ViewerFill {
    fn drop(&mut self) {
        let lock = tokio::sync::OwnedMutexGuard::mutex(self.guard.as_ref().expect("held"));
        let lock = lock.clone();
        self.guard = None;
        self.cache.forget_if_idle(self.viewer, &lock);
    }
}

impl SlotCache {
    fn lock(&self) -> std::sync::MutexGuard<'_, Inner> {
        self.inner
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// `Some(None)` is a cached "nothing to show"; `None` is a miss.
    pub(crate) fn get(&self, key: &SlotKey, now: Instant) -> Option<Option<SlotItem>> {
        let inner = self.lock();
        let (at, item) = inner.entries.get(key)?;
        (now.saturating_duration_since(*at) < TTL).then(|| item.clone())
    }

    /// Where a module's cache stands; pass it to [`Self::put`] with what a run that began now returns.
    pub(crate) fn generation(&self, module_id: &str) -> u64 {
        self.lock().generations.get(module_id).copied().unwrap_or(0)
    }

    /// Stores `item` unless the module was invalidated since `generation` was read.
    pub(crate) fn put(
        &self,
        key: SlotKey,
        item: Option<SlotItem>,
        (now, generation): (Instant, u64),
    ) {
        let mut inner = self.lock();
        if inner.generations.get(&key.module_id).copied().unwrap_or(0) != generation {
            return;
        }
        if inner.entries.len() >= MAX_ENTRIES {
            inner
                .entries
                .retain(|_, (at, _)| now.saturating_duration_since(*at) < TTL);
        }
        if inner.entries.len() < MAX_ENTRIES {
            inner.entries.insert(key, (now, item));
        }
    }

    /// Dropped when a module is disabled, updated, reconfigured or uninstalled.
    pub(crate) fn invalidate_module(&self, module_id: &str) {
        let mut inner = self.lock();
        inner.entries.retain(|key, _| key.module_id != module_id);
        *inner.generations.entry(module_id.to_owned()).or_default() += 1;
    }

    /// The viewer's place, waiting up to `wait` for their running fill; `None` if it is still going.
    pub(crate) async fn begin_fill(&self, viewer: UserId, wait: Duration) -> Option<ViewerFill> {
        let lock = self.lock().filling.entry(viewer).or_default().clone();
        let acquired = tokio::time::timeout(wait, lock.clone().lock_owned()).await;
        match acquired {
            Ok(guard) => {
                drop(lock);
                Some(ViewerFill {
                    cache: self.clone(),
                    viewer,
                    guard: Some(guard),
                })
            }
            Err(_) => {
                self.forget_if_idle(viewer, &lock);
                None
            }
        }
    }

    /// Drops the viewer's lock once nobody holds or awaits it.
    fn forget_if_idle(&self, viewer: UserId, lock: &Arc<tokio::sync::Mutex<()>>) {
        let mut inner = self.lock();
        let idle = Arc::strong_count(lock) == 2 && lock.try_lock().is_ok();
        if idle {
            inner.filling.remove(&viewer);
        }
    }

    #[cfg(test)]
    fn len(&self) -> usize {
        self.lock().entries.len()
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
        cache.put(k.clone(), None, (t0, 0));
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
        cache.put(xp.clone(), None, (now, 0));
        cache.put(other.clone(), None, (now, 0));
        cache.invalidate_module("xp");
        assert_eq!(cache.get(&xp, now), None);
        assert_eq!(cache.get(&other, now), Some(None));
    }

    #[test]
    fn the_cache_is_bounded_and_makes_room_by_dropping_expired_entries() {
        let cache = SlotCache::default();
        let t0 = Instant::now();
        for _ in 0..MAX_ENTRIES {
            cache.put(key("xp", UserId::generate()), None, (t0, 0));
        }
        cache.put(key("xp", UserId::generate()), None, (t0, 0));
        assert_eq!(cache.len(), MAX_ENTRIES, "full and fresh: not stored");
        let later = t0 + Duration::from_secs(31);
        cache.put(key("xp", UserId::generate()), None, (later, 0));
        assert_eq!(cache.len(), 1, "expired entries made room");
    }

    #[test]
    fn an_answer_from_before_an_invalidation_is_not_stored_after_it() {
        let cache = SlotCache::default();
        let k = key("xp", UserId::generate());
        let now = Instant::now();
        let began = cache.generation("xp");
        cache.invalidate_module("xp");
        cache.put(k.clone(), None, (now, began));
        assert_eq!(cache.get(&k, now), None, "the stale run was not stored");
        cache.put(k.clone(), None, (now, cache.generation("xp")));
        assert_eq!(cache.get(&k, now), Some(None));
    }

    #[tokio::test]
    async fn a_second_fill_waits_for_the_first_and_gives_up_after_the_bound() {
        let cache = SlotCache::default();
        let (ada, bob) = (UserId::generate(), UserId::generate());
        let wait = Duration::from_millis(50);
        let first = cache.begin_fill(ada, wait).await.expect("the first fill");
        assert!(
            cache.begin_fill(bob, wait).await.is_some(),
            "others are not held up"
        );
        assert!(
            cache.begin_fill(ada, wait).await.is_none(),
            "gave up after the bound"
        );

        let waiting = tokio::spawn({
            let cache = cache.clone();
            async move {
                cache
                    .begin_fill(ada, Duration::from_secs(5))
                    .await
                    .is_some()
            }
        });
        tokio::time::sleep(Duration::from_millis(20)).await;
        drop(first);
        assert!(
            waiting.await.unwrap(),
            "the waiter got its turn when the first finished"
        );
        assert!(cache.lock().filling.is_empty(), "idle locks are not kept");
    }
}
