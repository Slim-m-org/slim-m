// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Cross-origin access, for a browser build of the client.
//!
//! [`CorsPolicy`] is the same two-state shape as [`crate::push::PushSender`]
//! and [`crate::voice::VoiceService`], except that here the disabled state is
//! the default rather than a fallback. Nothing but a browser enforces the
//! same-origin policy, so a native client sends no `Origin` and is untouched
//! by any of this; the only deployment that needs a policy at all is one
//! serving the web client from a different origin than the API, and that
//! operator can say so.
//!
//! Three decisions here are security decisions rather than convenience ones.
//!
//! - **Unset means no layer at all, not an open one.** A self-host is very
//!   often on a private network that the operator's browser can route to and
//!   the internet cannot. An open policy would hand every page they visit the
//!   ability to drive that deployment from inside the perimeter, which is the
//!   one thing its network position was protecting it from.
//! - **`*` is refused outright**, at startup, rather than accepted as a
//!   shortcut. It is the same exposure as the paragraph above, just written
//!   deliberately, and there is no deployment that needs it: the origins a
//!   web client is served from are a short list the operator knows.
//! - **`Access-Control-Allow-Credentials` is never sent.** This API
//!   authenticates with an `Authorization: Bearer` header that a web client
//!   holds itself and attaches explicitly. Browsers never attach it
//!   automatically, so credentialed mode would buy nothing here while adding
//!   the ambient cookie and TLS-client-certificate authority that makes a
//!   mistaken origin catastrophic rather than merely wrong.
//!
//! A malformed entry fails the process at startup, for the same reason the
//! push relay URL's scheme is checked there: the alternative is an operator
//! discovering it from a browser console, on a path where the failure looks
//! like the server being down.

use std::time::Duration;

use anyhow::Context;
use axum::Router;
use axum::http::{HeaderName, HeaderValue, Method, header};
use tower_http::cors::{AllowOrigin, CorsLayer};
use url::Url;

use crate::config::Config;

/// How long a browser may reuse one preflight answer. Long enough that a
/// chatty client is not paying an extra round trip per request, short enough
/// that removing an origin takes effect within a coffee break.
const PREFLIGHT_MAX_AGE: Duration = Duration::from_secs(600);

/// The methods this API serves. `OPTIONS` is absent on purpose: it is
/// answered by the layer itself and never reaches a route.
const ALLOWED_METHODS: [Method; 5] = [
    Method::GET,
    Method::POST,
    Method::PUT,
    Method::PATCH,
    Method::DELETE,
];

/// Whether this deployment answers cross-origin browser requests, and for
/// which origins.
#[derive(Clone)]
pub struct CorsPolicy {
    layer: Option<CorsLayer>,
}

impl CorsPolicy {
    /// Builds the policy from config, refusing to start on a malformed or
    /// wildcard origin. An unset or empty list yields [`Self::disabled`].
    pub fn new(config: &Config) -> anyhow::Result<Self> {
        let origins = parse_origins(config.cors_allowed_origins.as_deref())?;
        if origins.is_empty() {
            tracing::info!(
                "SLIMM_CORS_ALLOWED_ORIGINS not set; cross-origin browser requests are refused"
            );
            return Ok(Self::disabled());
        }
        let allowed = origins
            .iter()
            .map(|origin| origin.to_str().unwrap_or_default())
            .collect::<Vec<_>>()
            .join(",");
        tracing::info!(%allowed, "cross-origin browser requests allowed for these origins");
        Ok(Self {
            layer: Some(layer_for(origins)),
        })
    }

    /// A policy that adds nothing to the router, so every cross-origin
    /// browser request is refused by the browser's own same-origin rule.
    pub fn disabled() -> Self {
        Self { layer: None }
    }

    /// A policy over an explicit origin list, for tests.
    pub fn for_test(origins: &str) -> anyhow::Result<Self> {
        Self::new(&Config {
            cors_allowed_origins: Some(origins.to_owned()),
            ..Config::default()
        })
    }

    pub fn is_enabled(&self) -> bool {
        self.layer.is_some()
    }

    /// Wraps `router` in this policy, or hands it back untouched when there
    /// is none.
    pub fn apply(self, router: Router) -> Router {
        match self.layer {
            Some(layer) => router.layer(layer),
            None => router,
        }
    }
}

/// Note the absence of `allow_credentials`: see the module docs.
fn layer_for(origins: Vec<HeaderValue>) -> CorsLayer {
    CorsLayer::new()
        .allow_origin(AllowOrigin::list(origins))
        .allow_methods(ALLOWED_METHODS)
        // The only two the client ever sets. Anything else a browser sends is
        // already on the CORS-safelist and needs no permission.
        .allow_headers([header::AUTHORIZATION, header::CONTENT_TYPE])
        // A script reads only the headers named here: a 429's retry time, and the Cloudflare ray whose suffix names the data centre.
        .expose_headers([header::RETRY_AFTER, HeaderName::from_static("cf-ray")])
        .max_age(PREFLIGHT_MAX_AGE)
}

/// Splits the configured list, skipping blank entries so a trailing comma is
/// not an outage.
fn parse_origins(raw: Option<&str>) -> anyhow::Result<Vec<HeaderValue>> {
    let Some(raw) = raw else {
        return Ok(Vec::new());
    };
    raw.split(',')
        .map(str::trim)
        .filter(|entry| !entry.is_empty())
        .map(validate_origin)
        .collect()
}

/// Turns one configured entry into the exact bytes a browser will send in its
/// `Origin` header, or explains why it cannot.
fn validate_origin(entry: &str) -> anyhow::Result<HeaderValue> {
    if entry == "*" {
        anyhow::bail!(
            "SLIMM_CORS_ALLOWED_ORIGINS may not contain \"*\": that lets any page on the \
             internet drive this deployment from a visitor's browser, including a deployment \
             on a private network nothing else can reach. List each origin you serve the web \
             client from instead."
        );
    }

    let url = Url::parse(entry).with_context(|| {
        format!("SLIMM_CORS_ALLOWED_ORIGINS entry {entry:?} is not a valid origin")
    })?;

    if !matches!(url.scheme(), "http" | "https") {
        anyhow::bail!(
            "SLIMM_CORS_ALLOWED_ORIGINS entry {entry:?} has scheme {:?}; a browser origin is \
             always http:// or https://",
            url.scheme()
        );
    }
    // A browser sends scheme, host and port and nothing else, so an entry
    // carrying more than that would silently never match what it describes.
    if url.path() != "/"
        || url.query().is_some()
        || url.fragment().is_some()
        || !url.username().is_empty()
    {
        anyhow::bail!(
            "SLIMM_CORS_ALLOWED_ORIGINS entry {entry:?} carries a path, query, fragment or \
             credentials; an origin is scheme://host[:port] and nothing more"
        );
    }
    if url.host().is_none() {
        anyhow::bail!("SLIMM_CORS_ALLOWED_ORIGINS entry {entry:?} has no host");
    }

    // Normalizing through the URL parser is what makes a default port, an
    // uppercase host, a unicode host or a bare trailing slash still match.
    let origin = url.origin().ascii_serialization();
    HeaderValue::from_str(&origin).with_context(|| {
        format!("SLIMM_CORS_ALLOWED_ORIGINS entry {entry:?} is not usable as a header value")
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn origins(raw: &str) -> Vec<String> {
        parse_origins(Some(raw))
            .expect("valid")
            .iter()
            .map(|value| value.to_str().unwrap().to_owned())
            .collect()
    }

    #[test]
    fn an_unset_or_empty_list_means_no_layer_at_all() {
        assert!(parse_origins(None).expect("unset is fine").is_empty());
        assert!(parse_origins(Some("")).expect("empty is fine").is_empty());
        assert!(
            parse_origins(Some(" , "))
                .expect("blank is fine")
                .is_empty()
        );

        assert!(!CorsPolicy::disabled().is_enabled());
        assert!(
            !CorsPolicy::for_test("")
                .expect("empty is fine")
                .is_enabled()
        );
        assert!(
            CorsPolicy::for_test("https://app.example.com")
                .expect("valid")
                .is_enabled()
        );
    }

    #[test]
    fn a_wildcard_is_refused_at_startup() {
        let err = parse_origins(Some("*")).expect_err("the wildcard must not be accepted");
        assert!(err.to_string().contains("may not contain"), "{err}");
        // Not just as a lone entry: hiding it in a list must fail too.
        assert!(parse_origins(Some("https://app.example.com,*")).is_err());
    }

    #[test]
    fn a_malformed_origin_fails_the_process_rather_than_a_browser_later() {
        for bad in [
            "app.example.com",
            "https://app.example.com/app",
            "https://app.example.com/?x=1",
            "https://app.example.com/#top",
            "https://user:pw@app.example.com",
            "ftp://app.example.com",
            "file:///srv/app",
            "null",
            "https://",
        ] {
            assert!(
                parse_origins(Some(bad)).is_err(),
                "{bad} should be refused at startup"
            );
        }
    }

    #[test]
    fn entries_are_normalized_to_what_a_browser_actually_sends() {
        assert_eq!(
            origins("https://app.example.com/, http://localhost:8099"),
            ["https://app.example.com", "http://localhost:8099"]
        );
        // A default port and a mixed-case host are both dropped by a browser
        // before it builds the header, so an entry keeping them must still match.
        assert_eq!(
            origins("https://App.Example.COM:443"),
            ["https://app.example.com"]
        );
        assert_eq!(origins("http://example.com:80"), ["http://example.com"]);
        assert_eq!(
            origins("https://exämple.com"),
            ["https://xn--exmple-cua.com"]
        );
    }

    #[test]
    fn a_trailing_comma_is_not_an_outage() {
        assert_eq!(
            origins("https://app.example.com,"),
            ["https://app.example.com"]
        );
    }
}
