// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The guarded GET behind [`super::ssrf`]: bounded in time ([`Limits`] plus the
//! client's stall timeout) and in body size, so a hostile or slow response cannot tie up
//! the server, the same shape `http::link_preview::fetch` uses for an
//! arbitrary-host fetch.

use std::time::Duration;

use reqwest::{Client, StatusCode};
use url::Url;

use super::ssrf::{UrlError, validate};

/// Largest `index.json` this server will read.
pub(super) const MAX_INDEX_BYTES: usize = 256 * 1024;
/// Largest `manifest.json` this server will read.
pub(super) const MAX_MANIFEST_BYTES: usize = 64 * 1024;
/// Largest module artifact this server will fetch and store. A module is
/// pure compute with no wasm imports (see `crate::module_runtime`'s ABI doc),
/// so even a bundled language runtime compiled to wasm is expected to fit
/// well inside this; sized generously above that rather than tightly, since
/// the real ceiling on what a module can do at run time is its own
/// `runtime.limits`, not this fetch cap.
pub(super) const MAX_ARTIFACT_BYTES: usize = 16 * 1024 * 1024;

/// How much body one fetch may read and how long the whole request may take.
/// The client itself only bounds a stalled connection, so a slow link keeps
/// moving a large artifact while a trickling host still runs out of `total`.
#[derive(Clone, Copy)]
pub(super) struct Limits {
    cap: usize,
    total: Duration,
}

impl Limits {
    pub(super) const INDEX: Self = Self::small(MAX_INDEX_BYTES);
    pub(super) const MANIFEST: Self = Self::small(MAX_MANIFEST_BYTES);
    /// Three minutes moves the 16 MiB cap at about 0.75 Mbit/s.
    pub(super) const ARTIFACT: Self = Self {
        cap: MAX_ARTIFACT_BYTES,
        total: Duration::from_secs(180),
    };

    const fn small(cap: usize) -> Self {
        Self {
            cap,
            total: Duration::from_secs(5),
        }
    }
}

/// What went wrong fetching from the Dock's one allowed host.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum FetchError {
    /// The URL is not well-formed, or does not point at the allowed host.
    Refused,
    /// A well-formed request to the allowed host that still could not be
    /// completed: unreachable, a non-200 other than [`FetchError::Missing`]'s,
    /// or the body ran over its cap.
    Unavailable,
    /// The host answered that nothing is there: a 404, or a redirect, which
    /// this client never follows. The only error [`fetch_first`] moves past.
    Missing,
}

impl From<UrlError> for FetchError {
    fn from(_: UrlError) -> Self {
        FetchError::Refused
    }
}

/// GETs [url] and returns its body within [limits]. [allowed_host]
/// gates every request through [`super::ssrf::validate`] first.
pub(super) async fn fetch_capped(
    client: &Client,
    url: &Url,
    allowed_host: &str,
    limits: Limits,
) -> Result<Vec<u8>, FetchError> {
    validate(url, allowed_host)?;
    let response = client
        .get(url.clone())
        .timeout(limits.total)
        .send()
        .await
        .map_err(|_| FetchError::Unavailable)?;
    let status = response.status();
    if status == StatusCode::NOT_FOUND || status.is_redirection() {
        return Err(FetchError::Missing);
    }
    if status != StatusCode::OK {
        return Err(FetchError::Unavailable);
    }
    read_capped(response, limits.cap).await
}

/// GETs [path] under each of [bases] in turn and returns the first body
/// found, moving on only when a base answers [`FetchError::Missing`]. An
/// outage stops the walk instead, so a down host costs one timeout rather
/// than one per base, and every candidate stays on [allowed_host].
pub(super) async fn fetch_first(
    client: &Client,
    bases: &[Url],
    path: &str,
    allowed_host: &str,
    limits: Limits,
) -> Result<Vec<u8>, FetchError> {
    for base in bases {
        let url = joined_under(base, path).ok_or(FetchError::Refused)?;
        match fetch_capped(client, &url, allowed_host, limits).await {
            Err(FetchError::Missing) => continue,
            found => return found,
        }
    }
    Err(FetchError::Missing)
}

/// [path] resolved against [base], or `None` if the result is not still on
/// [base]'s host and under its directory. A second line of defence behind the
/// manifest's own path rule, since `Url::join` reads `%2e%2e` and `\` as structure.
fn joined_under(base: &Url, path: &str) -> Option<Url> {
    let url = base.join(path).ok()?;
    let directory = &base.path()[..=base.path().rfind('/')?];
    let same_origin = url.scheme() == base.scheme()
        && url.host_str() == base.host_str()
        && url.port_or_known_default() == base.port_or_known_default();
    (same_origin && url.path().starts_with(directory)).then_some(url)
}

/// Reads at most [cap] bytes from [response], stopping the moment the body
/// runs over rather than buffering an unbounded one.
async fn read_capped(mut response: reqwest::Response, cap: usize) -> Result<Vec<u8>, FetchError> {
    let mut body = Vec::new();
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|_| FetchError::Unavailable)?
    {
        if body.len() + chunk.len() > cap {
            return Err(FetchError::Unavailable);
        }
        body.extend_from_slice(&chunk);
    }
    Ok(body)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn base() -> Url {
        Url::parse("https://raw.githubusercontent.com/alice/addons/main/").unwrap()
    }

    #[test]
    fn a_join_that_leaves_the_repo_directory_is_refused() {
        assert!(joined_under(&base(), "modules/a/0.1.0/module.wasm").is_some());
        for path in [
            "%2e%2e/%2e%2e/bob/evil/main/m.wasm",
            "\\bob\\evil\\main\\m.wasm",
            "../bob/m.wasm",
            "/bob/m.wasm",
            "https://elsewhere.test/m.wasm",
        ] {
            assert!(joined_under(&base(), path).is_none(), "{path}");
        }
    }
}
