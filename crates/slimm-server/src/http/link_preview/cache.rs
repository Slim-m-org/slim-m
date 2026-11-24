// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The in-process preview cache: one bounded, TTL'd map from a normalized URL
//! to its extracted preview, and a second from an image token to the image's
//! fetched bytes.
//!
//! The image token is signed and carries its own URL (see `image_token`), so
//! the endpoint takes a token, never a raw URL, and can only proxy an image a
//! real preview surfaced, and a token still works after a restart.
//! Same shape and eviction as `gifs::cache`.

use std::collections::HashMap;
use std::sync::{Mutex, MutexGuard};

use axum::body::Bytes;

use crate::store::now_ms;

use super::extract::Preview;
use super::fetch::FetchError;
use super::flight::{Flight, Flights};
use super::image_token;
use super::video::VideoInfo;

const CACHE_TTL_MS: i64 = 30 * 60 * 1000;
const MAX_ENTRIES: usize = 5_000;

/// Longest URL held as a cache key or minted into an image token; longer ones are served uncached.
const MAX_URL_CHARS: usize = 2_048;

/// Most (member, URL) sightings remembered; a forgotten one only costs that member one extra delay.
const MAX_SIGHTINGS: usize = 50_000;

/// The longest a first-time reader of a cached URL is held back, matching the fetch timeout.
const MAX_REPLAY_MS: u64 = 5_000;

/// Total image bytes held at once; the count bound alone allowed 5 MiB x 5000.
const MAX_IMAGE_BYTES: usize = 64 * 1024 * 1024;

/// How long a URL that yielded no preview is answered from memory, so a dead
/// link pasted into a busy channel costs one outbound fetch, not one per reader.
const MISS_TTL_MS: i64 = 60 * 1000;

/// What one fetch for a URL came to, shared with every request that asked for
/// the same URL while it was in flight.
#[derive(Clone)]
pub(super) enum Outcome {
    Found(Box<CachedPreview>),
    Missing,
    Refused,
}

/// The key a URL is cached under: parsed and re-serialized, so case in the
/// scheme and host, a default port and a `#fragment` (never sent upstream)
/// all land on one entry. An unparseable URL keys as itself; the handler has
/// already refused it by then anyway.
pub(super) fn cache_key(url: &str) -> String {
    match url::Url::parse(url) {
        Ok(mut parsed) => {
            parsed.set_fragment(None);
            parsed.into()
        }
        Err(_) => url.to_owned(),
    }
}

/// A preview as cached and served: the same fields [`Preview`] extracted,
/// with the image (if any) replaced by an opaque token the client redeems at
/// the image endpoint.
#[derive(Clone)]
pub(super) struct CachedPreview {
    pub title: Option<String>,
    pub description: Option<String>,
    pub site_name: Option<String>,
    pub image_token: Option<String>,
    pub video: Option<VideoInfo>,
    pub author_name: Option<String>,
    pub author_url: Option<String>,
    pub duration_s: Option<u32>,
    pub fetch_ms: u64,
    inserted_at: i64,
}

struct Miss {
    at: i64,
    fetch_ms: u64,
}

struct CachedImage {
    bytes: Bytes,
    inserted_at: i64,
}

pub(super) struct Cache {
    key: [u8; 32],
    previews: Mutex<HashMap<String, CachedPreview>>,
    misses: Mutex<HashMap<String, Miss>>,
    sightings: Mutex<HashMap<String, i64>>,
    in_flight: Flights<Outcome>,
    images: Mutex<HashMap<String, CachedImage>>,
    image_in_flight: Flights<Result<Bytes, FetchError>>,
}

impl Cache {
    pub(super) fn new(key: [u8; 32]) -> Self {
        Self {
            key,
            previews: Mutex::new(HashMap::new()),
            misses: Mutex::new(HashMap::new()),
            sightings: Mutex::new(HashMap::new()),
            in_flight: Flights::new(),
            images: Mutex::new(HashMap::new()),
            image_in_flight: Flights::new(),
        }
    }

    /// How long the fetch that found nothing for [key] took, if it was within the last [`MISS_TTL_MS`].
    pub(super) fn recently_missing(&self, key: &str) -> Option<u64> {
        lock(&self.misses)
            .get(key)
            .filter(|miss| now_ms() - miss.at < MISS_TTL_MS)
            .map(|miss| miss.fetch_ms)
    }

    pub(super) fn record_miss(&self, key: &str, fetch_ms: u64) {
        let now = now_ms();
        let mut misses = lock(&self.misses);
        misses.retain(|_, miss| now - miss.at < MISS_TTL_MS);
        misses.insert(
            key.to_owned(),
            Miss {
                at: now,
                fetch_ms: fetch_ms.min(MAX_REPLAY_MS),
            },
        );
    }

    /// Notes that [member] has now been answered for [key], returning whether they already had been.
    /// A first answer from the cache is held back by the original fetch time, so a reader cannot
    /// tell a URL someone else previewed from one nobody has.
    pub(super) fn mark_seen(&self, member: &str, key: &str) -> bool {
        let now = now_ms();
        let mut sightings = lock(&self.sightings);
        sweep(&mut sightings, |at| *at, now, MAX_SIGHTINGS);
        sightings.insert(format!("{member}\n{key}"), now).is_some()
    }

    /// The fetch every concurrent request for [key] shares.
    pub(super) fn in_flight(&self, key: &str) -> Flight<'_, Outcome> {
        self.in_flight.join(key)
    }

    /// The image fetch every concurrent request for [token] shares.
    pub(super) fn image_in_flight(&self, token: &str) -> Flight<'_, Result<Bytes, FetchError>> {
        self.image_in_flight.join(token)
    }

    /// The redeemable image token for [url]; the same for the same URL.
    pub(super) fn image_token_for(&self, url: &str) -> String {
        image_token::sign(&self.key, url)
    }

    /// The cached preview for [url], if still fresh.
    pub(super) fn preview(&self, url: &str) -> Option<CachedPreview> {
        let guard = lock(&self.previews);
        guard
            .get(url)
            .filter(|c| now_ms() - c.inserted_at < CACHE_TTL_MS)
            .cloned()
    }

    /// Caches [preview] under [url], minting an image token for its image (if
    /// any) and returning the cached shape the handler serves.
    pub(super) fn insert(&self, url: &str, preview: Preview, fetch_ms: u64) -> CachedPreview {
        let now = now_ms();
        let image_token = preview
            .image
            .as_ref()
            .filter(|image_url| image_url.chars().count() <= MAX_URL_CHARS)
            .map(|image_url| self.image_token_for(image_url));
        let cached = CachedPreview {
            title: preview.title,
            description: preview.description,
            site_name: preview.site_name,
            image_token,
            video: preview.video,
            author_name: preview.author_name,
            author_url: preview.author_url,
            duration_s: preview.duration_s,
            fetch_ms: fetch_ms.min(MAX_REPLAY_MS),
            inserted_at: now,
        };
        if url.chars().count() <= MAX_URL_CHARS {
            let mut previews = lock(&self.previews);
            sweep(&mut previews, |c| c.inserted_at, now, MAX_ENTRIES);
            previews.insert(url.to_owned(), cached.clone());
        }
        cached
    }

    /// The upstream image URL an image token stands for, if this server signed it.
    pub(super) fn image_url(&self, token: &str) -> Option<String> {
        image_token::verify(&self.key, token)
    }

    /// The already-fetched bytes for an image token, if still fresh.
    pub(super) fn image_bytes(&self, token: &str) -> Option<Bytes> {
        lock(&self.images)
            .get(token)
            .filter(|c| now_ms() - c.inserted_at < CACHE_TTL_MS)
            .map(|c| c.bytes.clone())
    }

    /// Records the fetched bytes for an image token, so the next viewer of
    /// the same card is served from memory rather than a fresh outbound fetch.
    pub(super) fn store_image_bytes(&self, token: &str, bytes: Bytes) {
        if bytes.len() > MAX_IMAGE_BYTES {
            return;
        }
        let now = now_ms();
        let mut images = lock(&self.images);
        sweep(&mut images, |c| c.inserted_at, now, MAX_ENTRIES);
        images.insert(
            token.to_owned(),
            CachedImage {
                bytes,
                inserted_at: now,
            },
        );
        evict_over_byte_budget(&mut images);
    }
}

/// Drops the oldest images until the held bytes fit [`MAX_IMAGE_BYTES`].
fn evict_over_byte_budget(images: &mut HashMap<String, CachedImage>) {
    let mut total: usize = images.values().map(|c| c.bytes.len()).sum();
    if total <= MAX_IMAGE_BYTES {
        return;
    }
    let mut by_age: Vec<(String, i64, usize)> = images
        .iter()
        .map(|(k, v)| (k.clone(), v.inserted_at, v.bytes.len()))
        .collect();
    by_age.sort_by_key(|(_, at, _)| *at);
    for (key, _, len) in by_age {
        if total <= MAX_IMAGE_BYTES {
            break;
        }
        images.remove(&key);
        total -= len;
    }
}

/// Drops expired entries, then, if still over the cap, the oldest half in one
/// pass - the same bounded eviction `gifs::cache` uses.
fn sweep<V>(map: &mut HashMap<String, V>, age_of: impl Fn(&V) -> i64, now: i64, cap: usize) {
    map.retain(|_, v| now - age_of(v) < CACHE_TTL_MS);
    if map.len() >= cap {
        let mut by_age: Vec<(String, i64)> =
            map.iter().map(|(k, v)| (k.clone(), age_of(v))).collect();
        by_age.sort_by_key(|(_, at)| *at);
        for (key, _) in by_age.into_iter().take(map.len() / 2) {
            map.remove(&key);
        }
    }
}

fn lock<V>(m: &Mutex<HashMap<String, V>>) -> MutexGuard<'_, HashMap<String, V>> {
    match m.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn preview_with_image() -> Preview {
        Preview {
            title: Some("T".to_owned()),
            description: Some("D".to_owned()),
            image: Some("https://cdn.example.com/a.png".to_owned()),
            site_name: Some("S".to_owned()),
            ..Preview::default()
        }
    }

    #[test]
    fn round_trips_a_preview_and_mints_an_image_token() {
        let cache = Cache::new([7; 32]);
        let cached = cache.insert("https://example.com", preview_with_image(), 0);
        let token = cached.image_token.clone().expect("an image mints a token");
        assert_eq!(
            cache
                .preview("https://example.com")
                .unwrap()
                .title
                .as_deref(),
            Some("T")
        );
        assert_eq!(
            cache.image_url(&token).as_deref(),
            Some("https://cdn.example.com/a.png")
        );
    }

    #[test]
    fn an_image_url_past_the_cap_mints_no_token() {
        let cache = Cache::new([7; 32]);
        let long = format!("https://cdn.example.com/{}", "a".repeat(MAX_URL_CHARS));
        let cached = cache.insert(
            "https://example.com",
            Preview {
                image: Some(long),
                ..Preview::default()
            },
            0,
        );
        assert!(cached.image_token.is_none());
    }

    #[test]
    fn a_url_past_the_cap_is_served_but_not_cached() {
        let cache = Cache::new([7; 32]);
        let long = format!("https://example.com/{}", "a".repeat(MAX_URL_CHARS));
        cache.insert(&long, preview_with_image(), 0);
        assert!(cache.preview(&long).is_none());
    }

    #[test]
    fn a_member_is_unseen_until_answered_once() {
        let cache = Cache::new([7; 32]);
        assert!(!cache.mark_seen("ada", "https://example.com"));
        assert!(cache.mark_seen("ada", "https://example.com"));
        assert!(!cache.mark_seen("bob", "https://example.com"));
    }

    #[test]
    fn an_imageless_preview_has_no_token() {
        let cache = Cache::new([7; 32]);
        let cached = cache.insert(
            "https://example.com",
            Preview {
                title: Some("T".to_owned()),
                ..Preview::default()
            },
            0,
        );
        assert!(cached.image_token.is_none());
    }

    #[test]
    fn stores_and_serves_image_bytes() {
        let cache = Cache::new([7; 32]);
        let cached = cache.insert("https://example.com", preview_with_image(), 0);
        let token = cached.image_token.unwrap();
        assert!(cache.image_bytes(&token).is_none());
        cache.store_image_bytes(&token, Bytes::from_static(&[1, 2, 3]));
        assert_eq!(cache.image_bytes(&token).unwrap().as_ref(), &[1, 2, 3]);
    }

    #[test]
    fn image_token_for_mints_a_redeemable_token() {
        let cache = Cache::new([7; 32]);
        let token = cache.image_token_for("https://cdn.example.com/embed.png");
        assert_eq!(
            cache.image_url(&token).as_deref(),
            Some("https://cdn.example.com/embed.png")
        );
    }

    #[test]
    fn image_token_for_reuses_the_same_token_for_the_same_url() {
        let cache = Cache::new([7; 32]);
        let first = cache.image_token_for("https://cdn.example.com/embed.png");
        let second = cache.image_token_for("https://cdn.example.com/embed.png");
        assert_eq!(
            first, second,
            "re-enriching the same embed must not churn the cache"
        );
    }

    #[test]
    fn image_token_for_mints_distinct_tokens_for_distinct_urls() {
        let cache = Cache::new([7; 32]);
        let a = cache.image_token_for("https://cdn.example.com/a.png");
        let b = cache.image_token_for("https://cdn.example.com/b.png");
        assert_ne!(a, b);
    }

    #[test]
    fn an_author_survives_the_round_trip() {
        let cache = Cache::new([7; 32]);
        let cached = cache.insert(
            "https://example.com",
            Preview {
                title: Some("A talk".to_owned()),
                author_name: Some("A Channel".to_owned()),
                author_url: Some("https://example.com/@achannel".to_owned()),
                ..Preview::default()
            },
            0,
        );
        assert_eq!(cached.author_name.as_deref(), Some("A Channel"));
        assert_eq!(
            cached.author_url.as_deref(),
            Some("https://example.com/@achannel")
        );
    }

    #[test]
    fn a_detected_video_survives_the_round_trip() {
        use super::super::video::{VideoInfo, VideoProvider};

        let cache = Cache::new([7; 32]);
        let cached = cache.insert(
            "https://example.com",
            Preview {
                title: Some("T".to_owned()),
                video: Some(VideoInfo {
                    provider: VideoProvider::Youtube,
                    id: "dQw4w9WgXcQ".to_owned(),
                    kind: None,
                    start_s: Some(42),
                }),
                ..Preview::default()
            },
            0,
        );
        let video = cached.video.expect("a video was set");
        assert_eq!(video.provider, VideoProvider::Youtube);
        assert_eq!(video.id, "dQw4w9WgXcQ");
        assert_eq!(video.start_s, Some(42));
    }

    #[test]
    fn an_image_token_still_redeems_after_a_restart() {
        let before = Cache::new([7; 32]);
        let token = before.image_token_for("https://cdn.example.com/a.png");
        let after = Cache::new([7; 32]);
        assert_eq!(
            after.image_url(&token).as_deref(),
            Some("https://cdn.example.com/a.png")
        );
    }

    fn image_at(len: usize, inserted_at: i64) -> CachedImage {
        CachedImage {
            bytes: Bytes::from(vec![0u8; len]),
            inserted_at,
        }
    }

    #[test]
    fn images_past_the_byte_budget_evict_the_oldest_first() {
        let chunk = 5 * 1024 * 1024;
        let mut images = HashMap::new();
        for i in 0..14 {
            images.insert(format!("t{i}"), image_at(chunk, now_ms() + i));
        }
        evict_over_byte_budget(&mut images);
        let held: usize = images.values().map(|c| c.bytes.len()).sum();
        assert!(held <= MAX_IMAGE_BYTES);
        assert!(!images.contains_key("t0") && !images.contains_key("t1"));
        assert!(images.contains_key("t13"), "the newest survives");
        assert_eq!(images.len(), MAX_IMAGE_BYTES / chunk);
    }

    #[test]
    fn a_single_image_larger_than_the_budget_is_not_cached() {
        let cache = Cache::new([7; 32]);
        cache.store_image_bytes("small", Bytes::from(vec![0u8; 10]));
        cache.store_image_bytes("huge", Bytes::from(vec![0u8; MAX_IMAGE_BYTES + 1]));
        assert!(cache.image_bytes("huge").is_none());
        assert!(cache.image_bytes("small").is_some(), "others are untouched");
    }

    #[test]
    fn storing_past_the_budget_keeps_the_held_bytes_bounded() {
        let cache = Cache::new([7; 32]);
        let chunk = 5 * 1024 * 1024;
        for i in 0..20 {
            cache.store_image_bytes(&format!("t{i}"), Bytes::from(vec![0u8; chunk]));
        }
        let held: usize = lock(&cache.images).values().map(|c| c.bytes.len()).sum();
        assert!(held <= MAX_IMAGE_BYTES);
        assert!(cache.image_bytes("t19").is_some());
    }

    #[test]
    fn the_entry_count_bound_still_applies_to_images() {
        let cache = Cache::new([7; 32]);
        for i in 0..MAX_ENTRIES + 10 {
            cache.store_image_bytes(&format!("t{i}"), Bytes::from_static(&[1]));
        }
        assert!(lock(&cache.images).len() <= MAX_ENTRIES);
    }
}
