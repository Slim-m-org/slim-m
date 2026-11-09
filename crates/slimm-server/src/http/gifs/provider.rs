// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Request dispatch for each supported GIF provider; the actual request and
//! response shape for each lives in its own submodule so this file stays a
//! plain dispatcher.
//!
//! Tenor's shape ([`tenor`]) is pinned against its own published v2 API docs
//! and exercised in tests against a fixture shaped exactly like a real
//! response. Klipy's ([`klipy`]) was originally modeled on public
//! third-party documentation of its API (Klipy's own `docs.klipy.com` blocks
//! automated fetches) and shipped broken: every live Klipy search errored,
//! because the real response nests each format under a quality tier
//! (`file.{hd,md,sm,xs}.{gif,webp,...}`, each an object carrying its own
//! `url`/`width`/`height`/`size`), not the flat `files.{gif,webp}` string map
//! the old code expected. `klipy`'s shape is checked against real captured
//! responses (search, trending, categories, and an invalid-key error) rather
//! than reasoned from documentation.

mod klipy;
mod tenor;

/// One search result, provider-shape already stripped away: a title and the
/// two upstream CDN URLs a caller may later fetch through, never handed to a
/// client directly (see the parent module's doc comment for why).
#[derive(Debug)]
pub(super) struct ProviderGif {
    pub(super) title: String,
    pub(super) preview_url: String,
    pub(super) full_url: String,
    /// The full-resolution image's own dimensions. Both Tenor and Klipy carry
    /// these on every result; `(0, 0)` only ever reaches a caller if a future
    /// provider's shape genuinely lacks them, and a client falls back to a
    /// fixed aspect ratio for those rather than treating zero as a real answer.
    pub(super) width: u32,
    pub(super) height: u32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Provider {
    Tenor,
    Klipy,
}

impl Provider {
    /// Case-insensitive, matching `SLIMM_GIF_PROVIDER`'s own doc comment.
    pub(super) fn parse(raw: &str) -> Option<Self> {
        match raw.to_ascii_lowercase().as_str() {
            "tenor" => Some(Provider::Tenor),
            "klipy" => Some(Provider::Klipy),
            _ => None,
        }
    }
}

/// Most results a single search asks a provider for; also this module's own
/// ceiling on what it will ever request, independent of whatever a caller
/// passed in.
pub(super) const MAX_LIMIT: u32 = 50;

/// `base_url` overrides each provider's real endpoint host, `None` in every
/// real deployment. It exists so a test can point this at a fake local
/// server rather than a live provider - production code never sets it, and
/// [`super::GifSearch::new`] never accepts one from configuration.
pub(super) async fn search(
    http: &reqwest::Client,
    provider: Provider,
    base_url: Option<&str>,
    api_key: &str,
    query: &str,
    limit: u32,
) -> anyhow::Result<Vec<ProviderGif>> {
    let limit = limit.clamp(1, MAX_LIMIT);
    match provider {
        Provider::Tenor => tenor::search(http, base_url, api_key, query, limit).await,
        Provider::Klipy => klipy::search(http, base_url, api_key, query, limit).await,
    }
    .map_err(without_url)
}

/// Like [`search`], but for a deployment's "what's popular right now" screen
/// rather than a query - the picker's own default content before a member
/// types anything. Both providers expose a dedicated endpoint for this
/// rather than an empty search, so it is a distinct request, not `search`
/// with `query` left blank.
pub(super) async fn trending(
    http: &reqwest::Client,
    provider: Provider,
    base_url: Option<&str>,
    api_key: &str,
    limit: u32,
) -> anyhow::Result<Vec<ProviderGif>> {
    let limit = limit.clamp(1, MAX_LIMIT);
    match provider {
        Provider::Tenor => tenor::trending(http, base_url, api_key, limit).await,
        Provider::Klipy => klipy::trending(http, base_url, api_key, limit).await,
    }
    .map_err(without_url)
}

/// A transport error prints the request URL, which carries the API key and the member's search words.
fn without_url(err: anyhow::Error) -> anyhow::Error {
    match err.downcast::<reqwest::Error>() {
        Ok(transport) => transport.without_url().into(),
        Err(other) => other,
    }
}

#[cfg(test)]
mod tests;
