// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The real dialler behind a module's `net.fetch`: reqwest with the shared
//! address guard (decision 0019), no redirects, and a capped body. Public
//! addresses only, unless the admin gave the separate local network approval,
//! which lifts only the private LAN ranges (see [`crate::net_guard`]).

use std::sync::{Arc, OnceLock};
use std::time::Duration;

use reqwest::header::{CONTENT_TYPE, HeaderName, HeaderValue, LOCATION};
use tokio::runtime::Handle;

use crate::module_runtime::{
    FetchRefused, FetchRequest, FetchResponse, HttpFetcher, MAX_FETCH_MS, MAX_RESPONSE_BODY_BYTES,
};
use crate::net_guard::{
    GuardResolver, LanGuardResolver, OwnAddresses, allowed_with_local_approval, is_blocked,
};

/// A run's wall clock is at most 10 s; one request may not take most of it.
const FETCH_TIMEOUT: Duration = Duration::from_millis(MAX_FETCH_MS);
const CONNECT_TIMEOUT: Duration = Duration::from_secs(3);
const TIMED_OUT: &str = "net.fetch timed out";
const LOCAL_REFUSED: &str = "only public addresses and private network devices can be reached, and private ones need the admin's local network approval";
/// What a run must keep in hand after a fetch to answer and return.
const RUN_HEADROOM: Duration = Duration::from_millis(150);

/// Which addresses a fetcher may dial.
#[derive(Clone, Copy)]
enum Policy {
    Public,
    /// Public, plus private LAN ranges: the admin's local network approval.
    Lan,
    /// Anything at all, so a test can reach the loopback listener it binds.
    #[cfg(test)]
    Anything,
}

pub(super) struct ReqwestFetcher {
    handle: Handle,
    policy: Policy,
}

impl ReqwestFetcher {
    pub(super) fn new(handle: Handle, allow_local: bool) -> Self {
        let policy = if allow_local {
            Policy::Lan
        } else {
            Policy::Public
        };
        Self { handle, policy }
    }

    #[cfg(test)]
    fn unguarded(handle: Handle) -> Self {
        Self {
            handle,
            policy: Policy::Anything,
        }
    }
}

/// One client per address policy, shared so connections and TLS setup are reused.
fn client(policy: Policy) -> &'static reqwest::Client {
    static PUBLIC: OnceLock<reqwest::Client> = OnceLock::new();
    static LAN: OnceLock<reqwest::Client> = OnceLock::new();
    #[cfg(test)]
    static ANYTHING: OnceLock<reqwest::Client> = OnceLock::new();
    let base = || {
        reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            // A proxy would do the DNS lookup the guard exists to check.
            .no_proxy()
            .connect_timeout(CONNECT_TIMEOUT)
            .user_agent(concat!("slim-m-module/", env!("CARGO_PKG_VERSION")))
    };
    let build = |builder: reqwest::ClientBuilder| {
        builder
            .build()
            .expect("a static reqwest client config builds")
    };
    match policy {
        Policy::Public => PUBLIC.get_or_init(|| {
            build(base().dns_resolver(Arc::new(GuardResolver {
                allow_private: false,
            })))
        }),
        Policy::Lan => LAN.get_or_init(|| build(base().dns_resolver(Arc::new(LanGuardResolver)))),
        #[cfg(test)]
        Policy::Anything => ANYTHING.get_or_init(|| {
            build(base().dns_resolver(Arc::new(GuardResolver {
                allow_private: true,
            })))
        }),
    }
}

impl HttpFetcher for ReqwestFetcher {
    fn fetch(
        &self,
        request: FetchRequest,
        remaining: Duration,
    ) -> Result<FetchResponse, FetchRefused> {
        if remaining <= RUN_HEADROOM {
            return Err(FetchRefused(TIMED_OUT.into()));
        }
        let budget = (remaining - RUN_HEADROOM).min(FETCH_TIMEOUT);
        self.handle.block_on(fetch(self.policy, request, budget))
    }
}

async fn fetch(
    policy: Policy,
    request: FetchRequest,
    budget: Duration,
) -> Result<FetchResponse, FetchRefused> {
    // A literal address never reaches the resolver, so it is judged here.
    if let Some(host) = request.url.host()
        && let Some(ip) = literal_ip(&host)
        && !literal_allowed(policy, ip)
    {
        return Err(FetchRefused(LOCAL_REFUSED.into()));
    }
    let mut builder = client(policy)
        .request(request.method, request.url)
        .timeout(budget);
    for (name, value) in request.headers {
        let (Ok(name), Ok(value)) = (
            HeaderName::from_bytes(name.as_bytes()),
            HeaderValue::from_str(&value),
        ) else {
            return Err(FetchRefused("net.fetch header is not valid".into()));
        };
        builder = builder.header(name, value);
    }
    if let Some(body) = request.body {
        builder = builder.body(body);
    }
    let mut response = builder.send().await.map_err(describe)?;
    let header = |name| {
        response
            .headers()
            .get(name)
            .and_then(|v: &HeaderValue| v.to_str().ok())
            .map(str::to_owned)
    };
    let content_type = header(CONTENT_TYPE);
    let location = header(LOCATION);
    let status = response.status().as_u16();
    let mut body = Vec::new();
    let mut truncated = false;
    while let Some(chunk) = response.chunk().await.map_err(describe)? {
        let room = MAX_RESPONSE_BODY_BYTES - body.len();
        if chunk.len() > room {
            body.extend_from_slice(&chunk[..room]);
            truncated = true;
            break;
        }
        body.extend_from_slice(&chunk);
    }
    Ok(FetchResponse {
        status,
        content_type,
        location,
        body: String::from_utf8_lossy(&body).into_owned(),
        truncated,
    })
}

fn literal_allowed(policy: Policy, ip: std::net::IpAddr) -> bool {
    match policy {
        Policy::Public => !is_blocked(ip),
        Policy::Lan => allowed_with_local_approval(ip, &OwnAddresses::detect()),
        #[cfg(test)]
        Policy::Anything => true,
    }
}

fn literal_ip(host: &url::Host<&str>) -> Option<std::net::IpAddr> {
    match host {
        url::Host::Ipv4(v4) => Some((*v4).into()),
        url::Host::Ipv6(v6) => Some((*v6).into()),
        url::Host::Domain(_) => None,
    }
}

/// Says why without echoing anything the upstream sent.
fn describe(err: reqwest::Error) -> FetchRefused {
    let mut source: Option<&dyn std::error::Error> = Some(&err);
    while let Some(e) = source {
        if e.to_string().contains("blocked address refused") {
            return FetchRefused(LOCAL_REFUSED.into());
        }
        source = e.source();
    }
    let reason = if err.is_timeout() {
        TIMED_OUT
    } else if err.is_connect() {
        "net.fetch could not connect"
    } else {
        "net.fetch failed"
    };
    FetchRefused(reason.into())
}

#[cfg(test)]
mod tests;
