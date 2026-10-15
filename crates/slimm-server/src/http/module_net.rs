// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The real dialler behind a module's `net.fetch`: reqwest with the shared
//! address guard (decision 0019), no redirects, and a capped body. Public
//! addresses only, unless the admin gave the separate local network approval.

use std::sync::{Arc, OnceLock};
use std::time::Duration;

use reqwest::header::{CONTENT_TYPE, HeaderName, HeaderValue, LOCATION};
use tokio::runtime::Handle;

use crate::module_runtime::{
    FetchRefused, FetchRequest, FetchResponse, HttpFetcher, MAX_RESPONSE_BODY_BYTES,
};
use crate::net_guard::{GuardResolver, is_blocked};

/// A run's wall clock is at most 10 s; one request may not take most of it.
const FETCH_TIMEOUT: Duration = Duration::from_secs(5);
const CONNECT_TIMEOUT: Duration = Duration::from_secs(3);
const LOCAL_REFUSED: &str = "local network addresses need the admin's local network approval";

pub(super) struct ReqwestFetcher {
    handle: Handle,
    allow_local: bool,
}

impl ReqwestFetcher {
    pub(super) fn new(handle: Handle, allow_local: bool) -> Self {
        Self {
            handle,
            allow_local,
        }
    }
}

/// One client per address policy, shared so connections and TLS setup are reused.
fn client(allow_local: bool) -> &'static reqwest::Client {
    static PUBLIC: OnceLock<reqwest::Client> = OnceLock::new();
    static LOCAL: OnceLock<reqwest::Client> = OnceLock::new();
    let cell = if allow_local { &LOCAL } else { &PUBLIC };
    cell.get_or_init(|| {
        reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .timeout(FETCH_TIMEOUT)
            .connect_timeout(CONNECT_TIMEOUT)
            .dns_resolver(Arc::new(GuardResolver {
                allow_private: allow_local,
            }))
            .user_agent(concat!("slim-m-module/", env!("CARGO_PKG_VERSION")))
            .build()
            .expect("a static reqwest client config builds")
    })
}

impl HttpFetcher for ReqwestFetcher {
    fn fetch(&self, request: FetchRequest) -> Result<FetchResponse, FetchRefused> {
        self.handle.block_on(fetch(self.allow_local, request))
    }
}

async fn fetch(allow_local: bool, request: FetchRequest) -> Result<FetchResponse, FetchRefused> {
    // A literal address never reaches the resolver, so it is judged here.
    if let Some(host) = request.url.host()
        && let Some(ip) = literal_ip(&host)
        && !allow_local
        && is_blocked(ip)
    {
        return Err(FetchRefused(LOCAL_REFUSED.into()));
    }
    let mut builder = client(allow_local).request(request.method, request.url);
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
        "net.fetch timed out"
    } else if err.is_connect() {
        "net.fetch could not connect"
    } else {
        "net.fetch failed"
    };
    FetchRefused(reason.into())
}

#[cfg(test)]
mod tests;
