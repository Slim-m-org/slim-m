// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! GIF search, proxied end to end so a client's search and every thumbnail
//! it renders reach the configured provider through this server rather than
//! directly - the same privacy reasoning `push.rs` already carries for a
//! relay: a member's own IP address, and their search terms, never reach
//! Tenor or Klipy on their own connection, only on this deployment's.
//!
//! Deliberately a first-class two-state thing, mirroring [`crate::push`] and
//! [`crate::voice`]: `SLIMM_GIF_PROVIDER` and `SLIMM_GIF_API_KEY` are both
//! optional, and a deployment with neither set simply has no GIF search,
//! which is a fully supported way to run this. `GET /version`'s
//! `gif_search_enabled` is what a client checks before ever showing the
//! picker, so a disabled deployment costs it nothing: no button, no request.
//!
//! Four routes, one flow: [`search`] asks the provider and hands back a
//! title plus an opaque token per result, never the provider's own CDN
//! URLs; [`trending`] is the same shape for a deployment's "what's popular
//! right now" screen, the picker's own default content before a member
//! types anything - Discord's own picker opens the same way, and there is no
//! reason to open ours to a blank grid when both supported providers already
//! expose a dedicated endpoint for it; [`preview`] streams a thumbnail
//! through this server for that token; [`select`] downloads the
//! full-resolution image through this server too and stores it exactly the
//! way [`super::attachments::upload`] stores a client-uploaded file, so the
//! result is an ordinary, already-self-hosted attachment id a send may
//! reference. Nothing downstream of a pick ever depends on the provider
//! again.
//!
//! Klipy also exposes a `gifs/categories` endpoint (a fixed list of
//! preset search terms, each with its own preview image) - deliberately not
//! wired up here. It would need its own proxied-preview plumbing for a
//! provider-hosted image that is not a search result at all, plus a second
//! picker surface (a category chip row) to make it reachable, and nothing
//! about "trending on open" needs it to be usable. Left as a follow-up
//! rather than silently dropped.
//!
//! The token a search hands back is a key into an in-memory, bounded,
//! TTL'd cache of the two real URLs it was minted from ([`Cache`]) - never the
//! URLs themselves, which is what keeps every later fetch routed through
//! this server. It is not durable and does not need to be: a search is
//! cheap to repeat, and nothing about a token surviving a restart is a
//! requirement anywhere in this flow.

mod cache;
mod filename;
mod provider;
#[cfg(test)]
mod tests;

use filename::{extension_for, slug_filename};

use std::sync::Arc;
use std::time::Duration;

use axum::Router;
use axum::extract::{Path, State};
use axum::http::{HeaderValue, StatusCode, header};
use axum::response::Response;
use axum::routing::{get, post};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use super::AppState;
use super::attachments::room_for;
use super::error::ApiError;
use super::extract::{ASSET, AuthedLimited, GIF, Json, Query};
use super::message_dto::AttachmentDto;
use crate::config::Config;
use crate::media;
use crate::permissions::Permissions;
use crate::store::AttachmentSummary;

use cache::Cache;
use provider::Provider;

/// A thumbnail is never stored, only relayed, so its cap is independent of
/// the operator's own attachment ceiling and is sized just for "a small
/// preview image".
const MAX_PREVIEW_BYTES: u64 = 5 * 1024 * 1024;

/// An outer sanity bound on a full-resolution download, independent of the
/// operator's own `SLIMM_ATTACHMENT_MAX_BYTES`: that ceiling is enforced
/// afterward, in [`select`], the same way [`super::attachments::upload`]
/// enforces it against a client-supplied body. This one is a sanity bound on a
/// provider the operator chose, not a hard memory ceiling: `Content-Length`
/// over it is refused before anything is downloaded, but a provider that sends
/// none - chunked transfer is ordinary - is still buffered whole by
/// [`fetch_capped`] and only then measured. What bounds that case is
/// [`PROVIDER_TIMEOUT`]. Making it a real ceiling means streaming the body,
/// which needs reqwest's `stream` feature that this workspace deliberately
/// cuts; see docs/dependencies.md.
const MAX_DOWNLOAD_BYTES: u64 = 25 * 1024 * 1024;

/// How long a provider request may take before this deployment gives up and
/// answers its own caller with a 503, rather than holding a connection open
/// indefinitely against a service outside its control.
const PROVIDER_TIMEOUT: Duration = Duration::from_secs(10);

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/gifs/search", get(search))
        .route("/gifs/trending", get(trending))
        .route("/gifs/preview/{token}", get(preview))
        .route("/gifs/select", post(select))
}

struct Enabled {
    http: reqwest::Client,
    provider: Provider,
    /// Overrides the provider's real endpoint host; always `None` in a real
    /// deployment. See `provider::search`'s own doc comment.
    base_url: Option<String>,
    api_key: String,
    cache: Cache,
}

/// What went wrong asking the provider or the cache, kept distinct from
/// [`ApiError`] so [`GifSearch`] never has to think about HTTP status codes;
/// each route below maps it once, at the edge.
enum GifError {
    /// No provider is configured at all.
    NotConfigured,
    /// A provider request failed. Retrying the same pick in a moment can
    /// work, because nothing about the caller's own token is wrong.
    Unavailable,
    /// The token names nothing this server still holds: its 15-minute TTL
    /// lapsed, a flood evicted it, or the process restarted and took the
    /// whole in-process cache with it.
    ///
    /// Split back out of [`GifError::Unavailable`], which used to carry it on
    /// the grounds that "a client's remedy is identical either way". It is
    /// not. A provider outage may clear on a retry of the same pick; a stale
    /// token never does, and only a fresh search mints one that works. Told
    /// apart, a client can reload its results instead of showing a picker
    /// whose every tile is already dead - which is what a restart leaves
    /// behind, and this deployment restarts on every merge to main.
    StaleToken,
}

/// This deployment's optional GIF search, cheap to clone (an
/// `Option<Arc<_>>`) so it lives directly on [`AppState`] the way
/// [`crate::push::PushSender`] and [`crate::voice::VoiceService`] already do.
#[derive(Clone)]
pub struct GifSearch {
    inner: Option<Arc<Enabled>>,
}

impl GifSearch {
    /// Builds from the process config. Disabled, quietly, unless both
    /// `gif_provider` and `gif_api_key` are set to something non-empty -
    /// an empty string reads the same as unset, the same treatment
    /// `SLIMM_CORS_ALLOWED_ORIGINS` already gives itself, because Compose's
    /// `${VAR:-}` interpolation hands the container an empty string rather
    /// than omitting the variable when an operator leaves it blank. Fails at
    /// startup - never silently disables - when a provider name is set but
    /// not recognized, the same treatment an unsafe push relay URL scheme
    /// gets, since a typo here should be caught before the process ever
    /// answers a request rather than discovered as "the GIF button just
    /// does nothing".
    pub fn new(config: &Config) -> anyhow::Result<Self> {
        let provider_raw = config.gif_provider.as_deref().filter(|s| !s.is_empty());
        let api_key = config.gif_api_key.as_deref().filter(|s| !s.is_empty());
        let (Some(provider_raw), Some(api_key)) = (provider_raw, api_key) else {
            return Ok(Self { inner: None });
        };
        let provider = Provider::parse(provider_raw).ok_or_else(|| {
            anyhow::anyhow!(
                "SLIMM_GIF_PROVIDER must be \"tenor\" or \"klipy\", got {provider_raw:?}"
            )
        })?;
        let http = reqwest::Client::builder()
            .timeout(PROVIDER_TIMEOUT)
            .build()?;
        Ok(Self {
            inner: Some(Arc::new(Enabled {
                http,
                provider,
                base_url: None,
                api_key: api_key.to_owned(),
                cache: Cache::new(),
            })),
        })
    }

    /// A disabled instance, for tests and for any deployment that set
    /// neither environment variable.
    pub fn disabled() -> Self {
        Self { inner: None }
    }

    /// Like [`Self::new`], but redirects the provider's search endpoint to
    /// `base_url` (a fake local server) instead of the real one - the seam
    /// `tests/gif_picker.rs` uses to drive the whole search-pick-select flow
    /// without ever reaching a live provider. Never called from production
    /// code, and there is no environment variable that reaches it.
    pub fn for_test(provider: &str, base_url: &str, api_key: &str) -> Self {
        let provider = Provider::parse(provider).expect("a recognized provider name in tests");
        Self {
            inner: Some(Arc::new(Enabled {
                http: reqwest::Client::new(),
                provider,
                base_url: Some(base_url.to_owned()),
                api_key: api_key.to_owned(),
                cache: Cache::new(),
            })),
        }
    }

    pub fn is_enabled(&self) -> bool {
        self.inner.is_some()
    }

    async fn search(&self, query: &str, limit: u32) -> Result<Vec<GifResultDto>, GifError> {
        let enabled = self.inner.as_deref().ok_or(GifError::NotConfigured)?;
        let hits = provider::search(
            &enabled.http,
            enabled.provider,
            enabled.base_url.as_deref(),
            &enabled.api_key,
            query,
            limit,
        )
        .await
        .map_err(|err| {
            tracing::warn!(%err, "gif provider search failed");
            GifError::Unavailable
        })?;
        Ok(mint_results(&enabled.cache, &hits))
    }

    /// Same wire shape and token-minting as [`Self::search`], against the
    /// provider's own trending endpoint instead of a query.
    async fn trending(&self, limit: u32) -> Result<Vec<GifResultDto>, GifError> {
        let enabled = self.inner.as_deref().ok_or(GifError::NotConfigured)?;
        let hits = provider::trending(
            &enabled.http,
            enabled.provider,
            enabled.base_url.as_deref(),
            &enabled.api_key,
            limit,
        )
        .await
        .map_err(|err| {
            tracing::warn!(%err, "gif provider trending fetch failed");
            GifError::Unavailable
        })?;
        Ok(mint_results(&enabled.cache, &hits))
    }

    async fn preview_bytes(&self, token: &str) -> Result<Vec<u8>, GifError> {
        let enabled = self.inner.as_deref().ok_or(GifError::NotConfigured)?;
        let url = enabled
            .cache
            .preview_url(token)
            .ok_or(GifError::StaleToken)?;
        fetch_capped(&enabled.http, &url, MAX_PREVIEW_BYTES).await
    }

    async fn download_full(&self, token: &str) -> Result<(Vec<u8>, String), GifError> {
        let enabled = self.inner.as_deref().ok_or(GifError::NotConfigured)?;
        let url = enabled.cache.full_url(token).ok_or(GifError::StaleToken)?;
        // The title rides back with the bytes so `select` can name the stored file after it, from the same entry the url came from.
        let title = enabled.cache.title(token).unwrap_or_default();
        let bytes = fetch_capped(&enabled.http, &url, MAX_DOWNLOAD_BYTES).await?;
        Ok((bytes, title))
    }
}

/// Mints a token per hit and turns it into the wire shape, shared by
/// [`GifSearch::search`] and [`GifSearch::trending`] since only where the
/// hits came from differs between them.
fn mint_results(cache: &Cache, hits: &[provider::ProviderGif]) -> Vec<GifResultDto> {
    hits.iter()
        .map(|gif| GifResultDto {
            id: cache.insert(gif),
            title: gif.title.clone(),
            width: gif.width,
            height: gif.height,
        })
        .collect()
}

/// Fetches `url` and refuses it past `max_bytes`, checked against
/// `Content-Length` first (when a provider sends one, this refuses before
/// downloading anything) and again while streaming the body (when it does not,
/// or lied). This deployment's own configured provider is a trusted third
/// party, not adversarial input the way an uploaded file is, so this is a
/// sanity bound rather than the hardened boundary `media::sniff_content_type`
/// is for a client-supplied body.
async fn fetch_capped(
    http: &reqwest::Client,
    url: &str,
    max_bytes: u64,
) -> Result<Vec<u8>, GifError> {
    let response = http.get(url).send().await.map_err(|err| {
        tracing::warn!(%err, "could not reach a gif provider's cdn");
        GifError::Unavailable
    })?;
    let response = response.error_for_status().map_err(|err| {
        tracing::warn!(%err, "a gif provider's cdn answered with an error");
        GifError::Unavailable
    })?;
    if response.content_length().is_some_and(|len| len > max_bytes) {
        return Err(GifError::Unavailable);
    }
    crate::net_guard::read_capped(response, max_bytes as usize)
        .await
        .map_err(|err| {
            tracing::warn!(?err, "could not read a gif provider's response body");
            GifError::Unavailable
        })
}

impl From<GifError> for ApiError {
    fn from(err: GifError) -> Self {
        match err {
            GifError::NotConfigured => {
                ApiError::NotConfigured("this deployment has no gif search configured")
            }
            GifError::Unavailable => ApiError::Unavailable,
            GifError::StaleToken => {
                ApiError::NotFound("that gif result has expired; search again to refresh them")
            }
        }
    }
}

// --- Wire types ---

#[derive(Serialize)]
struct GifResultDto {
    /// An opaque token, redeemable at `getGifPreview` and `selectGif` -
    /// never the provider's own id or CDN URL; see this module's own doc
    /// comment for why.
    id: String,
    title: String,
    width: u32,
    height: u32,
}

#[derive(Serialize)]
struct GifResultsDto {
    results: Vec<GifResultDto>,
}

#[derive(Deserialize)]
struct SearchParams {
    q: String,
    limit: Option<u32>,
}

#[derive(Deserialize)]
struct TrendingParams {
    limit: Option<u32>,
}

#[derive(Deserialize)]
struct SelectRequest {
    id: String,
}

const DEFAULT_LIMIT: u32 = 20;

// --- Handlers ---

/// Shared by every handler below: the whole point of this feature is to end
/// in an attachment, so someone who could not attach one anyway gets nothing
/// to browse either.
async fn require_attach_files(
    state: &AppState,
    user_id: crate::ids::UserId,
) -> Result<(), ApiError> {
    if state
        .store
        .base_permissions(user_id)
        .await?
        .contains(Permissions::ATTACH_FILES)
    {
        Ok(())
    } else {
        Err(ApiError::Forbidden)
    }
}

/// Requires deployment-wide `ATTACH_FILES`; see [`require_attach_files`].
async fn search(
    AuthedLimited(ctx): AuthedLimited<GIF>,
    Query(params): Query<SearchParams>,
    State(state): State<AppState>,
) -> Result<Json<GifResultsDto>, ApiError> {
    require_attach_files(&state, ctx.user_id).await?;
    let query = params.q.trim();
    if query.is_empty() {
        return Err(ApiError::BadRequest("q must not be empty"));
    }
    let limit = params
        .limit
        .unwrap_or(DEFAULT_LIMIT)
        .clamp(1, provider::MAX_LIMIT);
    let results = state.gifs.search(query, limit).await?;
    Ok(Json(GifResultsDto { results }))
}

/// The picker's default content before a member types a query; see this
/// module's own doc comment for why it exists. Requires deployment-wide
/// `ATTACH_FILES`; see [`require_attach_files`].
async fn trending(
    AuthedLimited(ctx): AuthedLimited<GIF>,
    Query(params): Query<TrendingParams>,
    State(state): State<AppState>,
) -> Result<Json<GifResultsDto>, ApiError> {
    require_attach_files(&state, ctx.user_id).await?;
    let limit = params
        .limit
        .unwrap_or(DEFAULT_LIMIT)
        .clamp(1, provider::MAX_LIMIT);
    let results = state.gifs.trending(limit).await?;
    Ok(Json(GifResultsDto { results }))
}

/// Streams a thumbnail through this server for a token `search` minted.
/// `Class::Asset`, not `Class::Gif`: a single result grid fires one of these
/// per tile, the same "many small reads on one screen" shape `getAttachment`
/// and `getAvatar` already carry that class for - `Class::Gif`'s tighter
/// budget is sized for the provider-facing calls (`search`, `select`), and a
/// twenty-result grid would exhaust it on its own thumbnails alone.
/// Never cached client-side as aggressively as a real attachment: the token
/// itself expires, so `Cache-Control` here is short rather than the
/// `getAttachment` immutable policy, which is a promise about content-hashed
/// bytes this response is not.
async fn preview(
    AuthedLimited(ctx): AuthedLimited<ASSET>,
    Path(token): Path<String>,
    State(state): State<AppState>,
) -> Result<Response, ApiError> {
    require_attach_files(&state, ctx.user_id).await?;
    let bytes = state.gifs.preview_bytes(&token).await?;
    // Unsniffable is the provider's doing, never the caller's own token.
    let content_type = media::sniff_content_type(&bytes).ok_or(ApiError::Unavailable)?;
    let mut response = Response::new(axum::body::Body::from(bytes));
    response
        .headers_mut()
        .insert(header::CONTENT_TYPE, HeaderValue::from_static(content_type));
    response.headers_mut().insert(
        header::CACHE_CONTROL,
        HeaderValue::from_static("private, max-age=600"),
    );
    Ok(response)
}

/// Downloads the full-resolution image through this server and stores it
/// exactly the way `uploadAttachment` stores a client-supplied body -
/// content-addressed, sniffed rather than trusted, checked against both size
/// ceilings - so what a send later references is an ordinary attachment with
/// no lingering dependency on the provider or the token that named it.
async fn select(
    AuthedLimited(ctx): AuthedLimited<GIF>,
    State(state): State<AppState>,
    Json(req): Json<SelectRequest>,
) -> Result<(StatusCode, Json<AttachmentDto>), ApiError> {
    require_attach_files(&state, ctx.user_id).await?;
    let (bytes, title) = state.gifs.download_full(&req.id).await?;
    if bytes.len() as u64 > state.media.max_attachment_bytes() {
        return Err(ApiError::BadRequest("gif is too large to attach"));
    }
    room_for(&state, bytes.len() as i64).await?;
    // Unsniffable is the provider's doing, never the caller's own token.
    let content_type = media::sniff_content_type(&bytes).ok_or(ApiError::Unavailable)?;
    // Named after the provider's title (slugged, falling back to "gif"), so a saved GIF is findable later rather than a wall of identical "gif.gif".
    let filename = format!("{}.{}", slug_filename(&title), extension_for(content_type));

    let sha256 = Sha256::digest(&bytes).to_vec();
    let hex_id = media::to_hex(&sha256);
    let size = bytes.len() as i64;

    state
        .media
        .write_attachment(&hex_id, bytes)
        .await
        .map_err(|err| {
            tracing::error!(error = %err, "failed to write a selected gif's bytes");
            ApiError::Internal
        })?;
    state
        .store
        .store_attachment(&sha256, size, content_type, &filename, Some(ctx.user_id))
        .await?;

    Ok((
        StatusCode::CREATED,
        Json(AttachmentDto::from(AttachmentSummary {
            id: hex_id,
            filename,
            content_type: content_type.to_owned(),
            size,
        })),
    ))
}
