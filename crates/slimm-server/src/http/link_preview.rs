// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Link unfurling: turning a pasted URL into a title/description/image
//! preview card, fetched server-side so a viewer's IP never reaches the
//! third-party host (the same privacy reasoning `gifs.rs` carries), and
//! behind the SSRF guard in [`ssrf`] because the fetched URL is entirely
//! attacker-controlled. See decision 0019.
//!
//! Opt-in per deployment: an operator turns it on with
//! `SLIMM_LINK_PREVIEWS=true`, off by default, so an outbound-fetch surface
//! is never exposed unless the operator asked for it. An admin can then
//! override that for the space (`PATCH /space/link-previews`). `GET /version`'s
//! `link_previews_enabled` is what a client checks before ever asking.
//!
//! [`video`] recognizes a playable video link (YouTube today) during this
//! same unfurl, from the page's own URL/OpenGraph tags - no extra request.
//! The privacy point of a click-to-play affordance is that a client loads
//! nothing from the video provider until the reader taps, so detection has
//! to happen here rather than the client guessing from the URL alone: this
//! is already the one place an SSRF-guarded fetch and an allowlist decision
//! are made for a pasted link.
//!
//! A recognized video's title/thumbnail/channel are a separate matter from
//! detection: [`oembed`] fills them in from the provider's oembed endpoint,
//! a second SSRF-guarded request behind the same [`fetch::follow`] the page
//! fetch uses, made only for a recognized video and never for an ordinary
//! link. Best-effort like the rest of this module: a failed or slow oembed
//! request degrades to a generic title and no channel rather than failing
//! the unfurl.

mod cache;
mod extract;
mod fetch;
#[cfg(test)]
mod fetch_tests;
mod image_token;
mod oembed;
mod ssrf;
mod video;

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use axum::Router;
use axum::body::Bytes;
use axum::extract::{Path, State};
use axum::http::{HeaderValue, header};
use axum::response::Response;
use axum::routing::get;
use serde::{Deserialize, Serialize};

use super::AppState;
use super::error::ApiError;
use super::extract::{ASSET, AuthedLimited, LINK_PREVIEW, Query};
use crate::config::Config;
use crate::media;

use cache::{Cache, CachedPreview};
use fetch::{FetchError, build_client, fetch_image, fetch_preview};
use ssrf::validate;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/link-preview", get(preview))
        .route("/link-preview/image/{token}", get(image))
}

/// This deployment's optional link unfurling, cheap to clone (an
/// `Option<Arc<_>>`) so it lives directly on [`AppState`] the way
/// [`super::gifs::GifSearch`] does.
#[derive(Clone)]
pub struct LinkPreviews {
    inner: Option<Arc<Enabled>>,
    /// Whether the space currently unfurls links: the operator's default
    /// until an admin overrides it.
    active: Arc<AtomicBool>,
    operator_default: bool,
}

struct Enabled {
    client: reqwest::Client,
    cache: Cache,
    /// Only ever true under [`LinkPreviews::for_test`]; lets a test reach the
    /// loopback a fake upstream binds to. False in every production instance.
    allow_private: bool,
}

impl LinkPreviews {
    /// Starts on `SLIMM_LINK_PREVIEWS`, which is also the ceiling: an admin can
    /// turn previews off through [`Self::set_override`], never on past the operator. While off, every route here answers "not
    /// configured", exactly like GIF search with no provider set.
    /// [image_key] signs image tokens; see `image_token` for why it is persisted.
    pub fn new(config: &Config, image_key: [u8; 32]) -> Self {
        let inner = Arc::new(Enabled {
            client: build_client(false),
            cache: Cache::new(image_key),
            allow_private: false,
        });
        Self {
            inner: Some(inner),
            active: Arc::new(AtomicBool::new(config.link_previews)),
            operator_default: config.link_previews,
        }
    }

    /// A disabled instance, for a test that builds an [`AppState`] directly.
    pub fn disabled() -> Self {
        Self {
            inner: None,
            active: Arc::new(AtomicBool::new(false)),
            operator_default: false,
        }
    }

    /// Applies the admin's choice; None goes back to the operator's default.
    /// Unfurling fetches member-supplied URLs, so only the operator can allow it.
    pub fn set_override(&self, choice: Option<bool>) {
        let on = self.inner.is_some() && self.operator_default && choice.unwrap_or(true);
        self.active.store(on, Ordering::Relaxed);
    }

    /// An enabled instance for tests, so the SSRF guard and the not-found
    /// paths can be driven through the real router. No test upstream is
    /// reachable through it: the guard blocks the loopback a test server
    /// binds to, which is exactly the behavior worth exercising.
    pub fn for_test() -> Self {
        Self {
            inner: Some(Arc::new(Enabled {
                client: build_client(true),
                cache: Cache::new([7; 32]),
                allow_private: true,
            })),
            active: Arc::new(AtomicBool::new(true)),
            operator_default: true,
        }
    }

    pub fn is_enabled(&self) -> bool {
        self.live().is_some()
    }

    fn live(&self) -> Option<&Enabled> {
        self.inner
            .as_deref()
            .filter(|_| self.active.load(Ordering::Relaxed))
    }

    fn live_shared(&self) -> Option<Arc<Enabled>> {
        self.inner
            .clone()
            .filter(|_| self.active.load(Ordering::Relaxed))
    }

    fn enabled(&self) -> Result<&Enabled, ApiError> {
        self.live()
            .ok_or(ApiError::NotConfigured("link previews are not enabled"))
    }

    /// Resolves an embed image URL to a redeemable token, reusing the
    /// existing preview guard and cache - see decision 0030.
    pub(crate) fn embed_image_token(&self, url: &str) -> Option<String> {
        let service = self.live()?;
        validate(url, service.allow_private).ok()?;
        Some(service.cache.image_token_for(url))
    }

    /// The write-time check for [`Self::embed_image_token`], with no cache
    /// side effect.
    pub(crate) fn allows_embed_image(&self, url: &str) -> bool {
        self.live()
            .is_some_and(|service| validate(url, service.allow_private).is_ok())
    }
}

#[derive(Deserialize)]
struct PreviewParams {
    url: String,
}

/// The wire shape of a preview. `image_token` (when present) is redeemed at
/// `GET /link-preview/image/{token}`; the client never sees the upstream
/// image URL. `video_provider`/`video_id` are set together, only when the
/// linked page was recognized as a playable video (YouTube today): the
/// client renders a click-to-play affordance instead of the static card, and
/// nothing about that provider is ever contacted until the reader taps.
/// `author_name`/`author_url` are the page's author or publisher, if known -
/// a YouTube video's channel today, from the same oembed request that fills
/// in the video's title and thumbnail (see [`oembed`]).
#[derive(Serialize)]
struct LinkPreviewDto {
    url: String,
    title: Option<String>,
    description: Option<String>,
    site_name: Option<String>,
    image_token: Option<String>,
    video_provider: Option<video::VideoProvider>,
    video_id: Option<String>,
    author_name: Option<String>,
    author_url: Option<String>,
}

fn to_dto(url: &str, cached: CachedPreview) -> LinkPreviewDto {
    let video_provider = cached.video.as_ref().map(|v| v.provider);
    let video_id = cached.video.map(|v| v.id);
    LinkPreviewDto {
        url: url.to_owned(),
        title: cached.title,
        description: cached.description,
        site_name: cached.site_name,
        image_token: cached.image_token,
        video_provider,
        video_id,
        author_name: cached.author_name,
        author_url: cached.author_url,
    }
}

impl From<FetchError> for ApiError {
    fn from(err: FetchError) -> Self {
        match err {
            // A refused (blocked or malformed) URL is the caller's own doing.
            FetchError::Refused => ApiError::BadRequest("that link cannot be previewed"),
            // A public URL that simply did not yield a preview.
            FetchError::Unavailable => ApiError::NotFound("no preview available"),
        }
    }
}

async fn preview(
    AuthedLimited(_ctx): AuthedLimited<LINK_PREVIEW>,
    State(state): State<AppState>,
    Query(params): Query<PreviewParams>,
) -> Result<axum::Json<LinkPreviewDto>, ApiError> {
    let service = state.link_previews.enabled()?;
    // Reject a blocked or malformed URL before any outbound work.
    validate(&params.url, service.allow_private)
        .map_err(|_| ApiError::BadRequest("that link cannot be previewed"))?;

    let key = cache::cache_key(&params.url);
    if let Some(cached) = service.cache.preview(&key) {
        return Ok(axum::Json(to_dto(&params.url, cached)));
    }
    if service.cache.recently_missing(&key) {
        return Err(ApiError::NotFound("no preview available"));
    }
    let cell = service.cache.in_flight(&key);
    let fetched_here = std::sync::atomic::AtomicBool::new(false);
    let outcome = cell
        .get_or_init(|| async {
            fetched_here.store(true, Ordering::Relaxed);
            match fetch_preview(&service.client, &params.url, service.allow_private).await {
                Ok(Some(preview)) => cache::Outcome::Found(service.cache.insert(&key, preview)),
                Ok(None) | Err(FetchError::Unavailable) => {
                    service.cache.record_miss(&key);
                    cache::Outcome::Missing
                }
                Err(FetchError::Refused) => cache::Outcome::Refused,
            }
        })
        .await
        .clone();
    service.cache.finish(&key, &cell);
    match outcome {
        cache::Outcome::Found(cached) => {
            if fetched_here.load(Ordering::Relaxed) {
                warm_image(&state.link_previews, cached.image_token.clone());
            }
            Ok(axum::Json(to_dto(&params.url, cached)))
        }
        cache::Outcome::Missing => Err(ApiError::NotFound("no preview available")),
        cache::Outcome::Refused => Err(ApiError::BadRequest("that link cannot be previewed")),
    }
}

async fn image(
    AuthedLimited(_ctx): AuthedLimited<ASSET>,
    State(state): State<AppState>,
    Path(token): Path<String>,
) -> Result<Response, ApiError> {
    let service = state.link_previews.enabled()?;
    serve_image(load_image(service, &token).await?)
}

/// The image behind [token], fetched once however many readers ask at the same time, and a
/// failure remembered briefly so a dead image costs one outbound fetch, not one per reader.
async fn load_image(service: &Enabled, token: &str) -> Result<Bytes, ApiError> {
    if let Some(bytes) = service.cache.image_bytes(token) {
        return Ok(bytes);
    }
    let url = service.cache.image_url(token).ok_or(ApiError::NotFound(
        "that preview image is no longer available",
    ))?;
    if service.cache.recently_missing(token) {
        return Err(ApiError::NotFound("no preview available"));
    }
    let cell = service.cache.image_in_flight(token);
    let outcome = cell
        .get_or_init(|| async {
            match fetch_image(&service.client, &url, service.allow_private).await {
                Ok(bytes) => {
                    let bytes = Bytes::from(bytes);
                    service.cache.store_image_bytes(token, bytes.clone());
                    Ok(bytes)
                }
                Err(err) => {
                    if err == FetchError::Unavailable {
                        service.cache.record_miss(token);
                    }
                    Err(err)
                }
            }
        })
        .await
        .clone();
    service.cache.finish_image(token, &cell);
    Ok(outcome?)
}

/// Starts fetching a fresh preview's image, so the cards that render it find the bytes waiting.
fn warm_image(previews: &LinkPreviews, token: Option<String>) {
    let (Some(token), Some(service)) = (token, previews.live_shared()) else {
        return;
    };
    tokio::spawn(async move {
        let _ = load_image(&service, &token).await;
    });
}

/// Serves proxied image bytes with a content type sniffed from the bytes
/// themselves, never the upstream header, and `nosniff` so a browser cannot
/// be talked into treating a mislabelled body as HTML.
fn serve_image(bytes: Bytes) -> Result<Response, ApiError> {
    let content_type = media::sniff_content_type(&bytes).ok_or(ApiError::Unavailable)?;
    if !content_type.starts_with("image/") {
        return Err(ApiError::Unavailable);
    }
    let mut response = Response::new(axum::body::Body::from(bytes));
    let headers = response.headers_mut();
    headers.insert(header::CONTENT_TYPE, HeaderValue::from_static(content_type));
    headers.insert(
        header::X_CONTENT_TYPE_OPTIONS,
        HeaderValue::from_static("nosniff"),
    );
    headers.insert(
        header::CACHE_CONTROL,
        HeaderValue::from_static("private, max-age=1800"),
    );
    Ok(response)
}
