// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The token cache described in the parent module's own doc comment: an
//! opaque, bounded, TTL'd map from a search-minted token to the two real
//! upstream URLs it stands in for. Split out to keep `gifs.rs` under the
//! review budget.

use std::collections::HashMap;
use std::sync::{Mutex, MutexGuard};

use uuid::Uuid;

use crate::ids::UserId;
use crate::store::now_ms;

use super::provider;

/// How long a minted token stays redeemable. Generous next to how long a
/// person spends browsing one search's results, since nothing here re-mints
/// a token on expiry - it just goes back to "search again".
const CACHE_TTL_MS: i64 = 15 * 60 * 1000;

/// Most tokens held at once, across every caller. Bounds memory against a
/// sustained flood the way [`crate::ratelimit`]'s own bucket map already
/// bounds itself; past it, the oldest half is evicted in one pass rather
/// than one token at a time, so a sweep triggered by a flood does not itself
/// become the flood's cost.
const MAX_CACHE_ENTRIES: usize = 5_000;

/// Most live tokens one member holds, five full result pages. Past it that
/// member's own oldest tokens go first, so a flood ages out only the flooder's.
const MAX_ENTRIES_PER_OWNER: usize = 250;

/// Handed a search hit's own [`provider::ProviderGif`], picks a fresh opaque
/// token, caches the two real URLs behind it, and returns the wire shape a
/// client sees.
struct CachedGif {
    owner: UserId,
    preview_url: String,
    full_url: String,
    stamp_url: String,
    /// The provider's own title for this hit, kept so a selected GIF can be
    /// stored under a useful filename (slugged from this) instead of a bare
    /// "gif.gif" - see `gifs::select`.
    title: String,
    width: u32,
    height: u32,
    inserted_at: i64,
}

/// What a favorite keeps of a search hit: the real URLs, which outlive the token.
pub(crate) struct GifSnapshot {
    pub(crate) title: String,
    pub(crate) preview_url: String,
    pub(crate) full_url: String,
    pub(crate) width: u32,
    pub(crate) height: u32,
}

/// A plain `Mutex<HashMap<..>>`, the same shape
/// [`crate::push::debounce::Debounce`] already uses for an in-process,
/// best-effort table with no need for a dedicated cache crate.
pub(super) struct Cache {
    entries: Mutex<HashMap<String, CachedGif>>,
}

impl Cache {
    pub(super) fn new() -> Self {
        Self {
            entries: Mutex::new(HashMap::new()),
        }
    }

    /// Mints and caches a fresh token for `gif`, sweeping expired entries
    /// first and, only if the map is still over [`MAX_CACHE_ENTRIES`] after
    /// that, evicting the oldest half in one pass.
    pub(super) fn insert(&self, owner: UserId, gif: &provider::ProviderGif) -> String {
        let token = Uuid::now_v7().to_string();
        let now = now_ms();
        let mut guard = self.lock();
        guard.retain(|_, cached| now - cached.inserted_at < CACHE_TTL_MS);
        evict_owner_overflow(&mut guard, owner);
        if guard.len() >= MAX_CACHE_ENTRIES {
            let mut by_age: Vec<(String, i64)> = guard
                .iter()
                .map(|(key, cached)| (key.clone(), cached.inserted_at))
                .collect();
            by_age.sort_by_key(|(_, at)| *at);
            for (key, _) in by_age.into_iter().take(guard.len() / 2) {
                guard.remove(&key);
            }
        }
        guard.insert(
            token.clone(),
            CachedGif {
                owner,
                preview_url: gif.preview_url.clone(),
                full_url: gif.full_url.clone(),
                stamp_url: gif.stamp_url.clone(),
                title: gif.title.clone(),
                width: gif.width,
                height: gif.height,
                inserted_at: now,
            },
        );
        token
    }

    pub(super) fn preview_url(&self, token: &str) -> Option<String> {
        self.live(token, |cached| cached.preview_url.clone())
    }

    pub(super) fn full_url(&self, token: &str) -> Option<String> {
        self.live(token, |cached| cached.full_url.clone())
    }

    pub(super) fn stamp_url(&self, token: &str) -> Option<String> {
        self.live(token, |cached| cached.stamp_url.clone())
    }

    pub(super) fn snapshot(&self, token: &str) -> Option<GifSnapshot> {
        self.live(token, |cached| GifSnapshot {
            title: cached.title.clone(),
            preview_url: cached.preview_url.clone(),
            full_url: cached.full_url.clone(),
            width: cached.width,
            height: cached.height,
        })
    }

    pub(super) fn title(&self, token: &str) -> Option<String> {
        self.live(token, |cached| cached.title.clone())
    }

    /// The one lookup: an entry past its TTL reads as absent until an insert sweeps it.
    fn live<T>(&self, token: &str, read: impl FnOnce(&CachedGif) -> T) -> Option<T> {
        let now = now_ms();
        self.lock()
            .get(token)
            .filter(|cached| now - cached.inserted_at < CACHE_TTL_MS)
            .map(read)
    }

    fn lock(&self) -> MutexGuard<'_, HashMap<String, CachedGif>> {
        match self.entries.lock() {
            Ok(guard) => guard,
            Err(poisoned) => poisoned.into_inner(),
        }
    }
}

/// Drops the oldest of `owner`'s tokens so one more still fits under their cap.
fn evict_owner_overflow(entries: &mut HashMap<String, CachedGif>, owner: UserId) {
    let mut held: Vec<(String, i64)> = entries
        .iter()
        .filter(|(_, cached)| cached.owner == owner)
        .map(|(key, cached)| (key.clone(), cached.inserted_at))
        .collect();
    let Some(excess) = (held.len() + 1).checked_sub(MAX_ENTRIES_PER_OWNER) else {
        return;
    };
    // Tokens are UUIDv7, so the key breaks a tie within one millisecond in mint order.
    held.sort_by(|a, b| (a.1, &a.0).cmp(&(b.1, &b.0)));
    for (key, _) in held.into_iter().take(excess) {
        entries.remove(&key);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(preview: &str, full: &str, ago_ms: i64) -> CachedGif {
        CachedGif {
            owner: UserId::generate(),
            preview_url: preview.to_owned(),
            full_url: full.to_owned(),
            stamp_url: full.to_owned(),
            title: "a title".to_owned(),
            width: 0,
            height: 0,
            inserted_at: now_ms() - ago_ms,
        }
    }

    fn hit(preview: &str, full: &str) -> provider::ProviderGif {
        provider::ProviderGif {
            title: "a title".to_owned(),
            preview_url: preview.to_owned(),
            full_url: full.to_owned(),
            width: 100,
            height: 100,
            stamp_url: full.to_owned(),
        }
    }

    #[test]
    fn a_fresh_token_resolves_both_urls() {
        let cache = Cache::new();
        let token = cache.insert(UserId::generate(), &hit("https://p", "https://f"));
        assert_eq!(cache.preview_url(&token).as_deref(), Some("https://p"));
        assert_eq!(cache.full_url(&token).as_deref(), Some("https://f"));
    }

    #[test]
    fn an_unknown_token_resolves_nothing() {
        let cache = Cache::new();
        assert_eq!(cache.preview_url("nonexistent"), None);
        assert_eq!(cache.full_url("nonexistent"), None);
    }

    /// The sweep runs on every insert, so planting an already-expired entry
    /// directly and then inserting a fresh one proves the expired one is
    /// gone, without waiting out the real TTL.
    #[test]
    fn an_expired_entry_is_swept_on_the_next_insert() {
        let cache = Cache::new();
        cache.entries.lock().unwrap().insert(
            "stale".to_owned(),
            fixture("https://p", "https://f", CACHE_TTL_MS + 1),
        );
        cache.insert(UserId::generate(), &hit("https://p2", "https://f2"));
        assert_eq!(cache.preview_url("stale"), None);
    }

    /// Past the ceiling, the oldest half goes, not the newest - proven by
    /// planting one old and one fresh entry directly, filling the map to the
    /// ceiling with old ones, then inserting once more and checking survivors
    /// by age rather than by count alone.
    #[test]
    fn past_the_ceiling_the_oldest_half_is_evicted_not_the_newest() {
        let cache = Cache::new();
        {
            let mut guard = cache.entries.lock().unwrap();
            for i in 0..MAX_CACHE_ENTRIES {
                // Strictly increasing age, oldest first: index alone tells survivor from evicted.
                guard.insert(
                    format!("old-{i}"),
                    fixture("https://p", "https://f", (MAX_CACHE_ENTRIES - i) as i64),
                );
            }
        }
        cache.insert(
            UserId::generate(),
            &hit("https://newest-p", "https://newest-f"),
        );
        let guard = cache.entries.lock().unwrap();
        assert!(guard.len() <= MAX_CACHE_ENTRIES);
        // The oldest planted entry is gone; the freshest of the old batch survives.
        assert!(!guard.contains_key("old-0"));
        assert!(guard.contains_key(&format!("old-{}", MAX_CACHE_ENTRIES - 1)));
    }

    #[test]
    fn an_expired_token_does_not_redeem_before_a_sweep() {
        let cache = Cache::new();
        cache.entries.lock().unwrap().insert(
            "stale".to_owned(),
            fixture("https://p", "https://f", CACHE_TTL_MS + 1),
        );
        assert_eq!(cache.preview_url("stale"), None);
        assert_eq!(cache.full_url("stale"), None);
        assert_eq!(cache.stamp_url("stale"), None);
        assert_eq!(cache.title("stale"), None);
        assert!(cache.snapshot("stale").is_none());
    }

    #[test]
    fn one_members_flood_only_ages_out_their_own_tokens() {
        let cache = Cache::new();
        let bystander = UserId::generate();
        let flooder = UserId::generate();
        let kept = cache.insert(bystander, &hit("https://p", "https://f"));
        let first = cache.insert(flooder, &hit("https://p", "https://f"));
        for _ in 0..MAX_ENTRIES_PER_OWNER {
            cache.insert(flooder, &hit("https://p", "https://f"));
        }
        assert!(cache.preview_url(&kept).is_some());
        assert!(cache.preview_url(&first).is_none());
        let held = cache
            .entries
            .lock()
            .unwrap()
            .values()
            .filter(|cached| cached.owner == flooder)
            .count();
        assert_eq!(held, MAX_ENTRIES_PER_OWNER);
    }
}
