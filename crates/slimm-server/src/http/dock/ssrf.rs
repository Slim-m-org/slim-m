// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The Dock's host allowlist: unlike link unfurling, which validates an
//! arbitrary member-supplied URL against address ranges only, every Dock
//! fetch targets one fixed host (`raw.githubusercontent.com` in production;
//! see decision 0021's "only the repo slug is configurable" line, echoed in
//! `Config::addons_repo`'s own doc). So [`validate`] first checks the URL's
//! host is exactly the one this [`Dock`](super::Dock) was built with, then
//! reuses [`crate::net_guard`]'s address-range guard as defense in depth
//! against that host itself resolving somewhere it should not (the same
//! posture decision 0019 established for link previews).

use std::sync::Arc;
use std::time::Duration;

use reqwest::Client;
use reqwest::redirect::Policy;
use url::Url;

use crate::net_guard::GuardResolver;

/// Identifies the fetch as this server's Dock, the marketplace-browsing
/// counterpart to link preview's own user agent.
const USER_AGENT: &str = "slimm-dock/1.0 (+https://github.com/Slim-m-org/slim-m)";

/// Longest the connection may go without a byte; the whole-request bound is `fetch::Limits`.
const STALL_TIMEOUT: Duration = Duration::from_secs(5);
const CONNECT_TIMEOUT: Duration = Duration::from_secs(3);

#[derive(Debug, PartialEq, Eq)]
pub(super) enum UrlError {
    /// Not a well-formed http(s) URL.
    Invalid,
    /// Well-formed, but its host is not the one this Dock is allowed to
    /// dial - the only way a fetch is ever refused, since a fixed host is
    /// never a numeric literal for the range check to catch instead.
    Blocked,
}

/// Checks [raw] is a well-formed http(s) URL whose host exactly matches
/// [allowed_host] (case-insensitively; DNS hostnames are not case
/// sensitive). Never reachable through anything but [`super::Dock`]'s own
/// `base_url`, which is built from a fixed scheme and host, so this exists
/// to catch a manifest-declared `artifact.path` (or any other server-built
/// relative URL) that somehow escaped its base rather than a member-supplied
/// one - the same defense-in-depth reasoning link preview's own `validate`
/// documents.
pub(super) fn validate(raw: &Url, allowed_host: &str) -> Result<(), UrlError> {
    if raw.scheme() != "http" && raw.scheme() != "https" {
        return Err(UrlError::Invalid);
    }
    match raw.host_str() {
        Some(host) if host.eq_ignore_ascii_case(allowed_host) => Ok(()),
        _ => Err(UrlError::Blocked),
    }
}

/// The guarded client: its DNS resolver rejects blocked addresses the same
/// way link preview's does, and redirects are off - a Dock fetch never
/// needs to follow one, so refusing it outright is simpler than
/// re-validating each hop. `allow_private` is the `Dock::for_test` seam;
/// production passes `false`.
pub(super) fn build_client(allow_private: bool) -> Client {
    Client::builder()
        .dns_resolver(Arc::new(GuardResolver { allow_private }))
        .redirect(Policy::none())
        .read_timeout(STALL_TIMEOUT)
        .connect_timeout(CONNECT_TIMEOUT)
        .user_agent(USER_AGENT)
        .build()
        .expect("a client with no unusual TLS config always builds")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validate_accepts_the_exact_allowed_host_only() {
        let url = Url::parse("https://raw.githubusercontent.com/a/b").unwrap();
        assert!(validate(&url, "raw.githubusercontent.com").is_ok());
        assert_eq!(validate(&url, "evil.example.com"), Err(UrlError::Blocked));
    }

    #[test]
    fn validate_is_case_insensitive_on_the_host() {
        let url = Url::parse("https://Raw.GitHubUserContent.com/a").unwrap();
        assert!(validate(&url, "raw.githubusercontent.com").is_ok());
    }
}
