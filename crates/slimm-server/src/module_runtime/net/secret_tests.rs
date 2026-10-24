// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `{"secret": key}` header values (decision 0091): filled in only for an
//! approved host, refused when unset, and never shown in a debug print.

use std::sync::Mutex;
use std::time::Duration;

use super::{
    FetchRefused, FetchRequest, FetchResponse, HttpFetcher, MAX_FETCHES_PER_RUN, SecretSource,
    handle, handle_with_secrets,
};

#[derive(Default)]
struct Vault {
    asked: Mutex<Vec<String>>,
}

impl SecretSource for Vault {
    fn secret(&self, key: &str) -> Option<String> {
        self.asked.lock().unwrap().push(key.to_owned());
        (key == "api_key").then(|| "s3cret-value".to_owned())
    }
}

#[derive(Default)]
struct Recording {
    seen: Mutex<Vec<FetchRequest>>,
}

impl HttpFetcher for Recording {
    fn fetch(&self, request: FetchRequest, _: Duration) -> Result<FetchResponse, FetchRefused> {
        self.seen.lock().unwrap().push(request);
        Ok(FetchResponse {
            status: 200,
            content_type: None,
            location: None,
            body: "ok".into(),
            truncated: false,
        })
    }
}

fn hosts() -> Vec<String> {
    vec!["api.example.com".to_owned()]
}

fn call(vault: &Vault, fetcher: &Recording, request: &str) -> String {
    let mut budget = MAX_FETCHES_PER_RUN;
    let out = handle_with_secrets(
        (fetcher, vault),
        &hosts(),
        &mut budget,
        (request.as_bytes(), Duration::from_secs(5)),
    );
    String::from_utf8(out).unwrap()
}

#[test]
fn a_secret_header_is_filled_in_for_an_approved_host() {
    let (vault, fetcher) = (Vault::default(), Recording::default());
    let request = r#"{"url":"https://api.example.com/x","headers":{"Authorization":{"secret":"api_key"},"Accept":"text/plain"}}"#;
    let out = call(&vault, &fetcher, request);
    assert!(out.contains(r#""ok":true"#), "{out}");
    let seen = fetcher.seen.lock().unwrap();
    assert!(
        seen[0]
            .headers
            .contains(&("Authorization".into(), "s3cret-value".into()))
    );
    assert!(
        seen[0]
            .headers
            .contains(&("Accept".into(), "text/plain".into()))
    );
    assert!(!out.contains("s3cret-value"));
}

#[test]
fn a_secret_is_never_read_for_a_host_that_is_not_approved() {
    let (vault, fetcher) = (Vault::default(), Recording::default());
    let request =
        r#"{"url":"https://evil.example.net/x","headers":{"Authorization":{"secret":"api_key"}}}"#;
    let out = call(&vault, &fetcher, request);
    assert!(out.contains(r#""ok":false"#), "{out}");
    assert!(vault.asked.lock().unwrap().is_empty());
    assert!(fetcher.seen.lock().unwrap().is_empty());
}

#[test]
fn an_unset_secret_is_refused_by_name_without_dialling() {
    let (vault, fetcher) = (Vault::default(), Recording::default());
    let request = r#"{"url":"https://api.example.com/x","headers":{"X-Key":{"secret":"missing"}}}"#;
    let out = call(&vault, &fetcher, request);
    assert!(out.contains("not set: missing"), "{out}");
    assert!(fetcher.seen.lock().unwrap().is_empty());
}

#[test]
fn a_run_with_no_secret_source_refuses_secret_headers() {
    let fetcher = Recording::default();
    let mut budget = MAX_FETCHES_PER_RUN;
    let request =
        br#"{"url":"https://api.example.com/x","headers":{"X-Key":{"secret":"api_key"}}}"#;
    let out = handle(
        &fetcher,
        &hosts(),
        &mut budget,
        (request, Duration::from_secs(5)),
    );
    assert!(String::from_utf8(out).unwrap().contains(r#""ok":false"#));
}

#[test]
fn a_debug_print_of_a_request_hides_header_values() {
    let (vault, fetcher) = (Vault::default(), Recording::default());
    let request =
        r#"{"url":"https://api.example.com/x","headers":{"Authorization":{"secret":"api_key"}}}"#;
    call(&vault, &fetcher, request);
    let printed = format!("{:?}", fetcher.seen.lock().unwrap()[0]);
    assert!(!printed.contains("s3cret-value"), "{printed}");
    assert!(printed.contains("Authorization"));
}
