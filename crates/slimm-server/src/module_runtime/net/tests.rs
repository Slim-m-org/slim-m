// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
use std::sync::Mutex;

use super::*;

fn hosts(list: &[&str]) -> Vec<String> {
    list.iter().map(|h| h.to_string()).collect()
}

fn url(s: &str) -> Url {
    Url::parse(s).unwrap()
}

#[derive(Default)]
struct Recording {
    seen: Mutex<Vec<FetchRequest>>,
}

impl HttpFetcher for Recording {
    fn fetch(&self, request: FetchRequest) -> Result<FetchResponse, FetchRefused> {
        self.seen.lock().unwrap().push(request);
        Ok(FetchResponse {
            status: 200,
            content_type: Some("application/json".into()),
            location: None,
            body: "{\"up\":true}".into(),
            truncated: false,
        })
    }
}

fn text(bytes: &[u8]) -> String {
    String::from_utf8(bytes.to_vec()).unwrap()
}

#[test]
fn a_bare_host_entry_admits_only_the_default_port() {
    let approved = hosts(&["api.example.com"]);
    assert!(host_allowed(&url("https://api.example.com/v1"), &approved));
    assert!(host_allowed(&url("https://API.example.com/v1"), &approved));
    assert!(!host_allowed(
        &url("https://api.example.com:8443/"),
        &approved
    ));
    assert!(!host_allowed(
        &url("https://evil.api.example.com/"),
        &approved
    ));
    assert!(!host_allowed(
        &url("https://api.example.com.evil.net/"),
        &approved
    ));
}

#[test]
fn a_host_and_port_entry_admits_exactly_that_port() {
    let approved = hosts(&["jellyfin.lan:8096"]);
    assert!(host_allowed(
        &url("http://jellyfin.lan:8096/System/Info"),
        &approved
    ));
    assert!(!host_allowed(&url("http://jellyfin.lan/"), &approved));
    assert!(!host_allowed(&url("http://jellyfin.lan:8097/"), &approved));
}

#[test]
fn only_http_and_https_to_an_approved_host_parse() {
    let approved = hosts(&["api.example.com"]);
    assert!(parse(br#"{"url":"https://api.example.com/x"}"#, &approved).is_ok());
    for refused in [
        r#"{"url":"ftp://api.example.com/x"}"#,
        r#"{"url":"file:///etc/passwd"}"#,
        r#"{"url":"https://other.example.com/x"}"#,
        r#"{"url":"https://user:pw@api.example.com/x"}"#,
        r#"{"url":"not a url"}"#,
        r#"{}"#,
        r#"{"url":"https://api.example.com/x","method":"CONNECT"}"#,
        r#"{"url":"https://api.example.com/x","headers":{"Host":"internal"}}"#,
    ] {
        assert!(parse(refused.as_bytes(), &approved).is_err(), "{refused}");
    }
}

#[test]
fn an_oversized_body_is_refused() {
    let approved = hosts(&["api.example.com"]);
    let body = "x".repeat(MAX_REQUEST_BODY_BYTES + 1);
    let request = json!({"url":"https://api.example.com/x","method":"POST","body":body});
    assert!(parse(request.to_string().as_bytes(), &approved).is_err());
}

#[test]
fn an_allowed_request_reaches_the_fetcher_and_the_reply_carries_the_body() {
    let fetcher = Recording::default();
    let mut budget = MAX_FETCHES_PER_RUN;
    let out = text(&handle(
        &fetcher,
        &hosts(&["api.example.com"]),
        &mut budget,
        br#"{"url":"https://api.example.com/status","headers":{"Accept":"application/json"}}"#,
    ));
    assert!(out.contains(r#""ok":true"#), "{out}");
    assert!(out.contains(r#""status":200"#), "{out}");
    let seen = fetcher.seen.lock().unwrap();
    assert_eq!(seen.len(), 1);
    assert_eq!(seen[0].method, reqwest::Method::GET);
    assert_eq!(
        seen[0].headers,
        vec![("Accept".into(), "application/json".into())]
    );
}

#[test]
fn a_refused_request_never_reaches_the_fetcher() {
    let fetcher = Recording::default();
    let mut budget = MAX_FETCHES_PER_RUN;
    let out = text(&handle(
        &fetcher,
        &hosts(&["api.example.com"]),
        &mut budget,
        br#"{"url":"http://169.254.169.254/latest/meta-data"}"#,
    ));
    assert!(out.contains("host not approved"), "{out}");
    assert!(fetcher.seen.lock().unwrap().is_empty());
}

#[test]
fn the_per_run_budget_is_spent_per_attempt() {
    let fetcher = Recording::default();
    let mut budget = MAX_FETCHES_PER_RUN;
    let approved = hosts(&["api.example.com"]);
    for _ in 0..MAX_FETCHES_PER_RUN {
        handle(
            &fetcher,
            &approved,
            &mut budget,
            br#"{"url":"https://nope.example/"}"#,
        );
    }
    let out = text(&handle(
        &fetcher,
        &approved,
        &mut budget,
        br#"{"url":"https://api.example.com/"}"#,
    ));
    assert!(out.contains("budget for this run is exhausted"), "{out}");
    assert!(fetcher.seen.lock().unwrap().is_empty());
}
