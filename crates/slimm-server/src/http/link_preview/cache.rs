// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The in-process preview cache: one bounded, TTL'd map from a normalized URL
//! to its extracted preview, and a second from an opaque image token to the
//! upstream image URL it stands in for (and, once fetched, its bytes).
//!
//! The image token matters for more than caching: the image endpoint takes a
//! token, never a raw URL, so a client can only ever have the server proxy an
//! image that a real preview already surfaced - it is not an open image proxy.
//! Same shape and eviction as `gifs::cache`.

use std::collections::HashMap;
use std::sync::{Mutex, MutexGuard};

use uuid::Uuid;

use crate::store::now_ms;

use super::extract::Preview;
use super::video::VideoInfo;

const CACHE_TTL_MS: i64 = 30 * 60 * 1000;
const MAX_ENTRIES: usize = 5_000;

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
    inserted_at: i64,
}

struct CachedImage {
    url: String,
    bytes: Option<Vec<u8>>,
    inserted_at: i64,
}

pub(super) struct Cache {
    previews: Mutex<HashMap<String, CachedPreview>>,
    images: Mutex<HashMap<String, CachedImage>>,
    /// Reverse of `images`, so re-enriching the same embed reuses one token.
    image_tokens_by_url: Mutex<HashMap<String, (String, i64)>>,
}

impl Cache {
    pub(super) fn new() -> Self {
        Self {
            previews: Mutex::new(HashMap::new()),
            images: Mutex::new(HashMap::new()),
            image_tokens_by_url: Mutex::new(HashMap::new()),
        }
    }

    /// The redeemable image token for [url], reusing a fresh one if minted.
    pub(super) fn image_token_for(&self, url: &str) -> String {
        let now = now_ms();
        {
            let by_url = lock(&self.image_tokens_by_url);
            if let Some((token, inserted_at)) = by_url.get(url)
                && now - inserted_at < CACHE_TTL_MS
                && lock(&self.images).contains_key(token)
            {
                return token.clone();
            }
        }
        let token = Uuid::now_v7().to_string();
        {
            let mut images = lock(&self.images);
            sweep(&mut images, |c| c.inserted_at, now);
            images.insert(
                token.clone(),
                CachedImage {
                    url: url.to_owned(),
                    bytes: None,
                    inserted_at: now,
                },
            );
        }
        let mut by_url = lock(&self.image_tokens_by_url);
        sweep(&mut by_url, |(_, at)| *at, now);
        by_url.insert(url.to_owned(), (token.clone(), now));
        token
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
    pub(super) fn insert(&self, url: &str, preview: Preview) -> CachedPreview {
        let now = now_ms();
        let image_token = preview.image.as_ref().map(|image_url| {
            let token = Uuid::now_v7().to_string();
            let mut images = lock(&self.images);
            sweep(&mut images, |c| c.inserted_at, now);
            images.insert(
                token.clone(),
                CachedImage {
                    url: image_url.clone(),
                    bytes: None,
                    inserted_at: now,
                },
            );
            token
        });
        let cached = CachedPreview {
            title: preview.title,
            description: preview.description,
            site_name: preview.site_name,
            image_token,
            video: preview.video,
            author_name: preview.author_name,
            author_url: preview.author_url,
            inserted_at: now,
        };
        let mut previews = lock(&self.previews);
        sweep(&mut previews, |c| c.inserted_at, now);
        previews.insert(url.to_owned(), cached.clone());
        cached
    }

    /// The upstream image URL an image token stands for, if still held.
    pub(super) fn image_url(&self, token: &str) -> Option<String> {
        lock(&self.images).get(token).map(|c| c.url.clone())
    }

    /// The already-fetched bytes for an image token, if any.
    pub(super) fn image_bytes(&self, token: &str) -> Option<Vec<u8>> {
        lock(&self.images).get(token).and_then(|c| c.bytes.clone())
    }

    /// Records the fetched bytes for an image token, so the next viewer of
    /// the same card is served from memory rather than a fresh outbound fetch.
    pub(super) fn store_image_bytes(&self, token: &str, bytes: Vec<u8>) {
        if let Some(entry) = lock(&self.images).get_mut(token) {
            entry.bytes = Some(bytes);
        }
    }
}

/// Drops expired entries, then, if still over the cap, the oldest half in one
/// pass - the same bounded eviction `gifs::cache` uses.
fn sweep<V>(map: &mut HashMap<String, V>, age_of: impl Fn(&V) -> i64, now: i64) {
    map.retain(|_, v| now - age_of(v) < CACHE_TTL_MS);
    if map.len() >= MAX_ENTRIES {
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
        let cache = Cache::new();
        let cached = cache.insert("https://example.com", preview_with_image());
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
    fn an_imageless_preview_has_no_token() {
        let cache = Cache::new();
        let cached = cache.insert(
            "https://example.com",
            Preview {
                title: Some("T".to_owned()),
                ..Preview::default()
            },
        );
        assert!(cached.image_token.is_none());
    }

    #[test]
    fn stores_and_serves_image_bytes() {
        let cache = Cache::new();
        let cached = cache.insert("https://example.com", preview_with_image());
        let token = cached.image_token.unwrap();
        assert!(cache.image_bytes(&token).is_none());
        cache.store_image_bytes(&token, vec![1, 2, 3]);
        assert_eq!(cache.image_bytes(&token).unwrap(), vec![1, 2, 3]);
    }

    #[test]
    fn image_token_for_mints_a_redeemable_token() {
        let cache = Cache::new();
        let token = cache.image_token_for("https://cdn.example.com/embed.png");
        assert_eq!(
            cache.image_url(&token).as_deref(),
            Some("https://cdn.example.com/embed.png")
        );
    }

    #[test]
    fn image_token_for_reuses_the_same_token_for_the_same_url() {
        let cache = Cache::new();
        let first = cache.image_token_for("https://cdn.example.com/embed.png");
        let second = cache.image_token_for("https://cdn.example.com/embed.png");
        assert_eq!(
            first, second,
            "re-enriching the same embed must not churn the cache"
        );
    }

    #[test]
    fn image_token_for_mints_distinct_tokens_for_distinct_urls() {
        let cache = Cache::new();
        let a = cache.image_token_for("https://cdn.example.com/a.png");
        let b = cache.image_token_for("https://cdn.example.com/b.png");
        assert_ne!(a, b);
    }

    #[test]
    fn an_author_survives_the_round_trip() {
        let cache = Cache::new();
        let cached = cache.insert(
            "https://example.com",
            Preview {
                title: Some("A talk".to_owned()),
                author_name: Some("A Channel".to_owned()),
                author_url: Some("https://example.com/@achannel".to_owned()),
                ..Preview::default()
            },
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

        let cache = Cache::new();
        let cached = cache.insert(
            "https://example.com",
            Preview {
                title: Some("T".to_owned()),
                video: Some(VideoInfo {
                    provider: VideoProvider::Youtube,
                    id: "dQw4w9WgXcQ".to_owned(),
                }),
                ..Preview::default()
            },
        );
        let video = cached.video.expect("a video was set");
        assert_eq!(video.provider, VideoProvider::Youtube);
        assert_eq!(video.id, "dQw4w9WgXcQ");
    }
}
