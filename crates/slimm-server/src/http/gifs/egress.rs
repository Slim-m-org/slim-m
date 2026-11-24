// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Every outbound fetch the GIF routes make: which URLs may be fetched, the
//! client that fetches them, and the capped read.

use std::sync::Arc;

use crate::net_guard::GuardResolver;

use super::{Enabled, GifError, PROVIDER_TIMEOUT, provider};

/// Provider and CDN traffic never goes through a proxy and never follows a
/// redirect to anything but a named https host, so a hop cannot reach an
/// internal address the resolver guard would not see.
pub(super) fn build_client(allow_private: bool) -> reqwest::Client {
    reqwest::Client::builder()
        .dns_resolver(Arc::new(GuardResolver { allow_private }))
        .no_proxy()
        .redirect(reqwest::redirect::Policy::custom(|attempt| {
            if attempt.previous().len() >= MAX_REDIRECTS {
                attempt.error("too many redirects")
            } else if fetchable(attempt.url(), false) {
                attempt.follow()
            } else {
                attempt.error("redirect to a host this server will not fetch")
            }
        }))
        .timeout(PROVIDER_TIMEOUT)
        .build()
        .expect("a client with no unusual TLS config always builds")
}

const MAX_REDIRECTS: usize = 3;

/// Whether `url` may be fetched: https to a named host. An IP literal never
/// reaches the DNS resolver guard, so it is refused here instead.
pub(super) fn fetchable(url: &reqwest::Url, allow_private: bool) -> bool {
    allow_private || (url.scheme() == "https" && matches!(url.host(), Some(url::Host::Domain(_))))
}

/// A hit naming a URL this server would refuse to fetch is dropped before it is given a token.
pub(super) fn provider_urls_fetchable(gif: &provider::ProviderGif, allow_private: bool) -> bool {
    [&gif.preview_url, &gif.full_url, &gif.stamp_url]
        .into_iter()
        .all(|url| url_fetchable(url, allow_private))
}

pub(super) fn url_fetchable(url: &str, allow_private: bool) -> bool {
    reqwest::Url::parse(url).is_ok_and(|url| fetchable(&url, allow_private))
}

/// Fetches `url` and refuses it past `max_bytes`, checked against
/// `Content-Length` first (when a provider sends one, this refuses before
/// downloading anything) and again while streaming the body (when it does not,
/// or lied). This deployment's own configured provider is a trusted third
/// party, not adversarial input the way an uploaded file is, so this is a
/// sanity bound rather than the hardened boundary `media::sniff_content_type`
/// is for a client-supplied body.
pub(super) async fn fetch_capped(
    enabled: &Enabled,
    url: &str,
    max_bytes: u64,
) -> Result<Vec<u8>, GifError> {
    if !url_fetchable(url, enabled.allow_private) {
        tracing::warn!("refused a gif provider url this server will not fetch");
        return Err(GifError::Unavailable);
    }
    let response = enabled.http.get(url).send().await.map_err(|err| {
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
