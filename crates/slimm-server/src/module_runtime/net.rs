// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `net.fetch` (owner decision 2026-10-14): a module asks the host for one
//! HTTP request to a host its manifest listed and an admin approved. No raw
//! sockets, no redirects followed, and caps on calls, sizes and time. The
//! host decides what may be dialled; see [`HttpFetcher`].

use std::collections::BTreeMap;
use std::time::Duration;

use serde::Deserialize;
use serde_json::json;
use url::Url;

/// Most requests one run may make.
pub const MAX_FETCHES_PER_RUN: u32 = 4;
/// Largest request body a module may send.
pub const MAX_REQUEST_BODY_BYTES: usize = 64 * 1024;
/// Largest response body handed back; more is cut and flagged `truncated`.
pub const MAX_RESPONSE_BODY_BYTES: usize = 256 * 1024;
/// Most request headers a module may set.
const MAX_REQUEST_HEADERS: usize = 16;
/// Headers the host owns; a module setting one is refused.
const RESERVED_HEADERS: [&str; 5] = [
    "host",
    "content-length",
    "connection",
    "transfer-encoding",
    "upgrade",
];

/// What a module asked for, already checked against its approved hosts.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FetchRequest {
    pub method: reqwest::Method,
    pub url: Url,
    pub headers: Vec<(String, String)>,
    pub body: Option<String>,
}

/// What came back, with the body already capped.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FetchResponse {
    pub status: u16,
    pub content_type: Option<String>,
    pub location: Option<String>,
    pub body: String,
    pub truncated: bool,
}

/// Why the host refused or failed a request. Shown to the module verbatim.
#[derive(Debug)]
pub struct FetchRefused(pub String);

/// Performs a request the gate already allowed. The implementation owns the
/// address check (public only, unless the admin approved private network
/// addresses) and gives up inside `remaining`, the run's unspent wall clock, so
/// the module is still running when it hears about a slow upstream.
pub trait HttpFetcher: Send + Sync {
    fn fetch(
        &self,
        request: FetchRequest,
        remaining: Duration,
    ) -> Result<FetchResponse, FetchRefused>;
}

#[derive(Deserialize)]
struct RawRequest {
    #[serde(default)]
    method: Option<String>,
    #[serde(default)]
    url: Option<String>,
    #[serde(default)]
    headers: BTreeMap<String, String>,
    #[serde(default)]
    body: Option<String>,
}

/// Whether `url` names one of `hosts`, which are `host` or `host:port`
/// entries. A bare host entry admits only the scheme's default port.
pub fn host_allowed(url: &Url, hosts: &[String]) -> bool {
    let Some(host) = url.host_str() else {
        return false;
    };
    let host = host
        .trim_start_matches('[')
        .trim_end_matches(']')
        .to_ascii_lowercase();
    let with_port = url.port().map(|port| format!("{host}:{port}"));
    hosts.iter().any(|entry| match &with_port {
        Some(explicit) => entry == explicit,
        None => entry == &host,
    })
}

/// Parses and gates one request: http or https only, an approved host, a
/// known method, and bounded headers and body.
pub fn parse(request: &[u8], hosts: &[String]) -> Result<FetchRequest, String> {
    let raw: RawRequest =
        serde_json::from_slice(request).map_err(|_| "malformed net.fetch request".to_owned())?;
    let url = raw.url.ok_or("net.fetch needs a url")?;
    let url = Url::parse(&url).map_err(|_| "net.fetch url is not a valid URL".to_owned())?;
    if !matches!(url.scheme(), "http" | "https") {
        return Err("net.fetch allows only http and https".into());
    }
    if !url.username().is_empty() || url.password().is_some() {
        return Err("net.fetch url may not carry credentials".into());
    }
    if !host_allowed(&url, hosts) {
        let host = url.host_str().unwrap_or_default();
        return Err(format!("host not approved for this module: {host}"));
    }
    let method = match raw
        .method
        .as_deref()
        .unwrap_or("GET")
        .to_ascii_uppercase()
        .as_str()
    {
        "GET" => reqwest::Method::GET,
        "HEAD" => reqwest::Method::HEAD,
        "POST" => reqwest::Method::POST,
        "PUT" => reqwest::Method::PUT,
        "PATCH" => reqwest::Method::PATCH,
        "DELETE" => reqwest::Method::DELETE,
        _ => return Err("net.fetch method not allowed".into()),
    };
    if raw.headers.len() > MAX_REQUEST_HEADERS {
        return Err("net.fetch sets too many headers".into());
    }
    let mut headers = Vec::with_capacity(raw.headers.len());
    for (name, value) in raw.headers {
        let lower = name.to_ascii_lowercase();
        if RESERVED_HEADERS.contains(&lower.as_str()) {
            return Err(format!("net.fetch may not set the {lower} header"));
        }
        headers.push((name, value));
    }
    if raw
        .body
        .as_ref()
        .is_some_and(|b| b.len() > MAX_REQUEST_BODY_BYTES)
    {
        return Err("net.fetch request body is too large".into());
    }
    Ok(FetchRequest {
        method,
        url,
        headers,
        body: raw.body,
    })
}

/// Dispatches one `net.fetch` request, returning the UTF-8 JSON response.
/// `fetches_remaining` is this run's budget, spent per attempt, and `remaining`
/// the wall clock the run has left.
pub fn handle(
    fetcher: &dyn HttpFetcher,
    hosts: &[String],
    fetches_remaining: &mut u32,
    (request, remaining): (&[u8], Duration),
) -> Vec<u8> {
    if *fetches_remaining == 0 {
        return refusal("net.fetch budget for this run is exhausted");
    }
    *fetches_remaining -= 1;
    let parsed = match parse(request, hosts) {
        Ok(parsed) => parsed,
        Err(reason) => return refusal(&reason),
    };
    match fetcher.fetch(parsed, remaining) {
        Ok(response) => serde_json::to_vec(&json!({
            "ok": true,
            "status": response.status,
            "content_type": response.content_type,
            "location": response.location,
            "body": response.body,
            "truncated": response.truncated,
        }))
        .unwrap_or_else(|_| br#"{"ok":false,"error":"host error"}"#.to_vec()),
        Err(FetchRefused(reason)) => refusal(&reason),
    }
}

fn refusal(message: &str) -> Vec<u8> {
    serde_json::to_vec(&json!({ "ok": false, "error": message }))
        .unwrap_or_else(|_| br#"{"ok":false,"error":"host error"}"#.to_vec())
}

#[cfg(test)]
mod tests;
