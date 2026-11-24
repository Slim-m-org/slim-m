// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A failed provider request must not carry the API key or the search words
//! out of this module, because the caller logs the error.

use super::*;

const KEY: &str = "sekrit-api-key-7731";
const WORDS: &str = "private-search-words";

async fn refusing_server() -> String {
    let router =
        axum::Router::new().fallback(|| async { axum::http::StatusCode::TOO_MANY_REQUESTS });
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
    format!("http://{addr}")
}

async fn closed_port() -> String {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    drop(listener);
    format!("http://{addr}")
}

fn assert_scrubbed(err: &anyhow::Error) {
    for text in [err.to_string(), format!("{err:#}"), format!("{err:?}")] {
        assert!(!text.contains(KEY), "the key leaked: {text}");
        assert!(!text.contains(WORDS), "the search words leaked: {text}");
    }
}

#[tokio::test]
async fn a_search_that_cannot_connect_leaks_neither_the_key_nor_the_words() {
    let base = closed_port().await;
    let http = reqwest::Client::new();
    for provider in [Provider::Tenor, Provider::Klipy] {
        let err = search(&http, provider, Some(&base), KEY, WORDS, 5)
            .await
            .expect_err("nothing is listening");
        assert_scrubbed(&err);
    }
}

#[tokio::test]
async fn trending_that_cannot_connect_leaks_no_key() {
    let base = closed_port().await;
    let http = reqwest::Client::new();
    for provider in [Provider::Tenor, Provider::Klipy] {
        let err = trending(&http, provider, Some(&base), KEY, 5)
            .await
            .expect_err("nothing is listening");
        assert_scrubbed(&err);
    }
}

#[tokio::test]
async fn a_quota_refusal_leaks_neither_the_key_nor_the_words() {
    let base = refusing_server().await;
    let http = reqwest::Client::new();
    let err = search(&http, Provider::Tenor, Some(&base), KEY, WORDS, 5)
        .await
        .expect_err("a 429 is an error");
    assert!(err.to_string().contains("429"), "{err}");
    assert_scrubbed(&err);
}

#[tokio::test]
async fn a_provider_sentence_that_is_not_a_transport_error_passes_through() {
    let base = refusing_server().await;
    let http = reqwest::Client::new();
    let err = search(&http, Provider::Klipy, Some(&base), KEY, WORDS, 5)
        .await
        .expect_err("a 429 is an error");
    assert!(err.to_string().contains("klipy answered 429"), "{err}");
    assert_scrubbed(&err);
}

async fn serving(
    status: axum::http::StatusCode,
    body: impl Fn(String) -> Vec<u8> + Clone + Send + Sync + 'static,
) -> String {
    let router = axum::Router::new().fallback(move |uri: axum::http::Uri| {
        let body = body.clone();
        async move { (status, body(uri.to_string())) }
    });
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
    format!("http://{addr}")
}

#[tokio::test]
async fn klipys_error_body_naming_the_key_is_scrubbed_and_capped() {
    let base = serving(axum::http::StatusCode::NOT_FOUND, |uri| {
        format!("no route for {uri} {}", "x".repeat(10_000)).into_bytes()
    })
    .await;
    let err = search(
        &reqwest::Client::new(),
        Provider::Klipy,
        Some(&base),
        KEY,
        WORDS,
        5,
    )
    .await
    .expect_err("a 404 is an error");
    assert_scrubbed(&err);
    assert!(err.to_string().contains("[redacted]"), "{err}");
    assert!(err.to_string().chars().count() < 300, "{err}");
}

#[tokio::test]
async fn a_provider_body_past_the_read_cap_is_refused() {
    let big = vec![b' '; MAX_RESPONSE_BYTES + 1];
    for provider in [Provider::Tenor, Provider::Klipy] {
        let body = big.clone();
        let base = serving(axum::http::StatusCode::OK, move |_| body.clone()).await;
        let err = search(
            &reqwest::Client::new(),
            provider,
            Some(&base),
            KEY,
            WORDS,
            5,
        )
        .await
        .expect_err("an oversized body is refused");
        assert!(err.to_string().contains("oversized"), "{err}");
    }
}

#[tokio::test]
async fn one_malformed_result_costs_only_that_result() {
    let klipy = serde_json::json!({"data": {"data": [
        {"title": "bad", "file": {"xs": {"gif": {"url": 5, "width": "x", "height": 1}}}},
        {"title": "good", "file": {"hd": {"gif": {"url": "https://k.example/a.gif", "width": 4, "height": 4}}}},
    ]}});
    let tenor = serde_json::json!({"results": [
        {"content_description": "bad", "media_formats": {"gif": {"url": "https://t.example/a.gif", "dims": "none"}}},
        {"content_description": "good", "media_formats": {"gif": {"url": "https://t.example/b.gif", "dims": [4, 4], "size": 9}}},
    ]});
    for (provider, page) in [(Provider::Klipy, klipy), (Provider::Tenor, tenor)] {
        let body = page.to_string().into_bytes();
        let base = serving(axum::http::StatusCode::OK, move |_| body.clone()).await;
        let hits = search(
            &reqwest::Client::new(),
            provider,
            Some(&base),
            KEY,
            WORDS,
            5,
        )
        .await
        .expect("the page survives one bad item");
        assert_eq!(hits.len(), 1, "{provider:?}");
        assert_eq!(hits[0].title, "good");
    }
}
